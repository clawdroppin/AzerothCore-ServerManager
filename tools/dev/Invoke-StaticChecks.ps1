<#
  Static checks for the whole app - run before every commit:
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\dev\Invoke-StaticChecks.ps1
  Exit code 0 = clean. Checks:
    1. Every .ps1 parses (PowerShell 5.1 parser).
    2. Files with non-ASCII characters start with a UTF-8 BOM (PowerShell 5.1 reads BOM-less files as ANSI).
    3. ui\*.xaml is well-formed XML.
    4. JSON files in config\ parse.
    5. Nested .GetNewClosure() blocks that use a variable of the outer closure without re-binding it
       (a nested closure does NOT see the outer closure's captured variables - add "$x = $x" in the outer block).
    6. Event handlers / -OnDone callbacks inside functions that use the function's locals without .GetNewClosure()
       (they run later, after the function has returned, and would see $null).
#>
param([string]$Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference = 'Stop'
$problems = New-Object System.Collections.ArrayList
function Add-Problem([string]$m) { [void]$problems.Add($m); Write-Host "  ✖ $m" -ForegroundColor Red }
$A = [Management.Automation.Language.Parser]
$scripts = @(Get-ChildItem (Join-Path $Root 'src'), (Join-Path $Root 'payload'), (Join-Path $Root 'tools') -Recurse -Filter *.ps1)

Write-Host '1. Parse' -ForegroundColor Cyan
$asts = @{}
foreach ($f in $scripts) {
    $err = $null; $asts[$f.FullName] = $A::ParseFile($f.FullName, [ref]$null, [ref]$err)
    foreach ($e in @($err)) { if ($e) { Add-Problem "$($f.Name):$($e.Extent.StartLineNumber) $($e.Message)" } }
}

Write-Host '2. Encoding (BOM when non-ASCII)' -ForegroundColor Cyan
foreach ($f in $scripts + @(Get-ChildItem (Join-Path $Root 'config') -Filter *.json)) {
    $b = [IO.File]::ReadAllBytes($f.FullName)
    $bom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
    if (-not $bom -and ($b | Where-Object { $_ -gt 127 } | Select-Object -First 1)) { Add-Problem "$($f.Name): non-ASCII text without a UTF-8 BOM" }
}

Write-Host '3. XAML' -ForegroundColor Cyan
foreach ($f in Get-ChildItem (Join-Path $Root 'ui') -Filter *.xaml) {
    try { [void][xml][IO.File]::ReadAllText($f.FullName) } catch { Add-Problem "$($f.Name): $($_.Exception.Message)" }
}

Write-Host '4. JSON' -ForegroundColor Cyan
foreach ($f in Get-ChildItem (Join-Path $Root 'config') -Filter *.json) {
    try { [void]([IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json) } catch { Add-Problem "$($f.Name): $($_.Exception.Message)" }
}

Write-Host '5. Nested closures' -ForegroundColor Cyan
foreach ($f in $scripts) {
    $ast = $asts[$f.FullName]
    $sbs = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'GetNewClosure' -and $n.Expression -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true) | ForEach-Object Expression)
    foreach ($inner in $sbs) {
        $p = $inner.Parent; $outer = $null
        while ($p) { if ($sbs -contains $p) { $outer = $p; break }; $p = $p.Parent }
        if (-not $outer) { continue }
        $assigned = @($outer.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath })
        $params = @($outer.FindAll({ param($n) $n -is [Management.Automation.Language.ParameterAst] }, $true) | ForEach-Object { $_.Name.VariablePath.UserPath })
        $loops = @($outer.FindAll({ param($n) $n -is [Management.Automation.Language.ForEachStatementAst] }, $true) | ForEach-Object { $_.Variable.VariablePath.UserPath })
        # Variables the outer closure captured = used in it but not created in it.
        $used = @($inner.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object VariablePath |
            Where-Object { -not $_.IsGlobal -and -not $_.IsScript -and $_.UserPath -notmatch '^(_|args|true|false|null|this|PSItem|Error|ui|Window|App|ToolDir|Tasks|matches|input|LASTEXITCODE|ModuleTitles)$' } | ForEach-Object UserPath | Sort-Object -Unique)
        $fn = $outer.Parent; while ($fn -and $fn -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
        $fnLocals = if ($fn) { @($fn.Body.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath }) + @($fn.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) } else { @() }
        $missing = @($used | Where-Object { $_ -notin $assigned -and $_ -notin $params -and $_ -notin $loops -and $_ -in $fnLocals })
        if ($missing) { Add-Problem "$($f.Name):$($inner.Extent.StartLineNumber) nested closure uses '$($missing -join "', '")' from the outer closure (add `$x = `$x at the top of the outer block)" }
    }
}

Write-Host '6. Handlers without closures' -ForegroundColor Cyan
foreach ($f in $scripts) {
    $ast = $asts[$f.FullName]
    foreach ($sb in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.ScriptBlockExpressionAst] }, $true)) {
        $parent = $sb.Parent
        if ($parent -is [Management.Automation.Language.MemberExpressionAst] -and $parent.Expression -eq $sb) { continue }
        $isHandler = $parent -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $parent.Member.Value -like 'Add_*'
        if ($parent -is [Management.Automation.Language.CommandAst]) {
            $els = $parent.CommandElements; $i = [array]::IndexOf($els, $sb)
            if ($i -gt 0 -and $els[$i - 1] -is [Management.Automation.Language.CommandParameterAst] -and $els[$i - 1].ParameterName -eq 'OnDone') { $isHandler = $true }
        }
        if (-not $isHandler) { continue }
        $fn = $sb.Parent; while ($fn -and $fn -isnot [Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
        if (-not $fn) { continue }
        $outside = { param($n) $n.Extent.StartOffset -lt $sb.Extent.StartOffset -or $n.Extent.StartOffset -gt $sb.Extent.EndOffset }
        $locals = @($fn.Body.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] }, $true) |
            Where-Object { & $outside $_ } | ForEach-Object { $_.Left.VariablePath } | Where-Object { -not $_.IsScript -and -not $_.IsGlobal } | ForEach-Object UserPath)
        $locals += @($fn.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $locals += @($fn.Body.FindAll({ param($n) $n -is [Management.Automation.Language.ParamBlockAst] }, $false) | ForEach-Object { $_.Parameters } | ForEach-Object { $_.Name.VariablePath.UserPath })
        $inner = @($sb.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object { $_.Left.VariablePath.UserPath }) +
                 @($sb.FindAll({ param($n) $n -is [Management.Automation.Language.ParameterAst] }, $true) | ForEach-Object { $_.Name.VariablePath.UserPath })
        $used = @($sb.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] }, $true) | ForEach-Object VariablePath | Where-Object { -not $_.IsScript -and -not $_.IsGlobal } | ForEach-Object UserPath | Sort-Object -Unique)
        $bad = @($used | Where-Object { $_ -in $locals -and $_ -notin $inner -and $_ -notin '_', 'this', 'args', 'true', 'false', 'null' })
        if ($bad) { Add-Problem "$($f.Name):$($sb.Extent.StartLineNumber) handler in $($fn.Name) uses locals '$($bad -join "', '")' without .GetNewClosure()" }
    }
}

if ($problems.Count) { Write-Host "`n$($problems.Count) problem(s)." -ForegroundColor Red; exit 1 }
Write-Host "`nAll static checks passed ($($scripts.Count) scripts)." -ForegroundColor Green
exit 0
