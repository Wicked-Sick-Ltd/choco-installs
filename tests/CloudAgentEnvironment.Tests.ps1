Set-StrictMode -Version Latest

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'Cloud agent environment' {
    It 'runs the Linux bootstrap from environment.json' {
        $path = Join-Path $script:RepoRoot '.cursor/environment.json'
        $cfg = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $cfg.install | Should -Be 'bash .cursor/install.sh'
        @($cfg.PSObject.Properties.Name) | Should -Be @('name', 'install')
    }

    It 'does not execute the Windows Chocolatey script' {
        $path = Join-Path $script:RepoRoot '.cursor/install.sh'
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match 'set -euo pipefail'
        $text | Should -Match "optional tool 'choco'"
        $invocations = Select-String -LiteralPath $path -Pattern 'install\.ps1' |
            Where-Object { $_.Line -match '\b(pwsh|powershell|bash)\b' -and $_.Line -notmatch 'WARNING' }
        @($invocations).Count | Should -Be 0
    }
}

Describe 'PowerShell scripts' {
    It 'parse without being executed' {
        $scripts = @(Get-ChildItem -LiteralPath $script:RepoRoot -Filter '*.ps1' -Recurse -File)
        $scripts.Count | Should -BeGreaterThan 0
        foreach ($scriptFile in $scripts) {
            $tokens = $null
            $parseErrors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile(
                $scriptFile.FullName,
                [ref]$tokens,
                [ref]$parseErrors
            )
            @($parseErrors).Count | Should -Be 0 -Because $scriptFile.FullName
        }
    }
}

Describe 'Chocolatey package list' {
    It 'is a unique list of package ids and is not executed' {
        $path = Join-Path $script:RepoRoot 'install.ps1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $path,
            [ref]$tokens,
            [ref]$parseErrors
        )
        @($parseErrors).Count | Should -Be 0

        $assignment = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -eq 'packages'
            }, $true) | Select-Object -First 1
        $assignment | Should -Not -BeNullOrEmpty

        $names = @(
            $assignment.Right.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
                }, $true) | ForEach-Object { $_.Value }
        )

        $names.Count | Should -BeGreaterThan 0
        $names | Should -Not -Contain ''
        foreach ($name in $names) {
            $name | Should -Match '^[a-z0-9][a-z0-9.+_-]*$'
        }
        @($names | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
    }
}
