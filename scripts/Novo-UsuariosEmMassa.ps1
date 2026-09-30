<#
.SYNOPSIS
    Cria usuários no Active Directory em massa a partir de um arquivo CSV.

.DESCRIPTION
    Lê um CSV com os dados dos usuários, valida cada linha, cria a conta na OU
    informada, adiciona aos grupos e grava um log com o resultado de cada linha.
    Usuários que já existem são ignorados (não são sobrescritos).

    Suporta -WhatIf: mostra o que seria feito sem criar nada.

.PARAMETER CaminhoCsv
    Caminho do arquivo CSV. Colunas esperadas:
    Nome, Sobrenome, Login, Departamento, Cargo, OU, Grupos (separados por ;)

.PARAMETER Dominio
    Sufixo do UPN. Ex.: lab.local

.PARAMETER PastaLog
    Pasta onde o log será salvo. Padrão: .\logs

.EXAMPLE
    .\Novo-UsuariosEmMassa.ps1 -CaminhoCsv ..\exemplos\usuarios.csv -Dominio lab.local -WhatIf

.EXAMPLE
    .\Novo-UsuariosEmMassa.ps1 -CaminhoCsv ..\exemplos\usuarios.csv -Dominio lab.local

.NOTES
    Requer o módulo ActiveDirectory (RSAT) e permissão para criar usuários.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CaminhoCsv,

    [Parameter(Mandatory)]
    [string]$Dominio,

    [string]$PastaLog = ".\logs"
)

Import-Module ActiveDirectory -ErrorAction Stop

if (-not (Test-Path $PastaLog)) { New-Item -ItemType Directory -Path $PastaLog | Out-Null }
$arquivoLog = Join-Path $PastaLog ("criacao-usuarios_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date))

function New-SenhaTemporaria {
    # Senha aleatória de 14 caracteres com maiúscula, minúscula, número e símbolo
    $maiusculas = 'ABCDEFGHJKLMNPQRSTUVWXYZ'.ToCharArray()
    $minusculas = 'abcdefghijkmnopqrstuvwxyz'.ToCharArray()
    $numeros    = '23456789'.ToCharArray()
    $simbolos   = '!@#$%*?'.ToCharArray()
    $todos      = $maiusculas + $minusculas + $numeros + $simbolos

    $senha  = @()
    $senha += Get-Random -InputObject $maiusculas
    $senha += Get-Random -InputObject $minusculas
    $senha += Get-Random -InputObject $numeros
    $senha += Get-Random -InputObject $simbolos
    $senha += 1..10 | ForEach-Object { Get-Random -InputObject $todos }
    -join ($senha | Sort-Object { Get-Random })
}

$usuarios   = Import-Csv -Path $CaminhoCsv -Encoding UTF8
$resultados = New-Object System.Collections.Generic.List[object]
$linha      = 1

foreach ($u in $usuarios) {
    $linha++
    $status = ''
    $detalhe = ''

    try {
        # Validação básica
        foreach ($campo in 'Nome','Sobrenome','Login','OU') {
            if ([string]::IsNullOrWhiteSpace($u.$campo)) { throw "Campo obrigatório vazio: $campo" }
        }

        $login = $u.Login.Trim().ToLower()

        if (Get-ADUser -Filter "SamAccountName -eq '$login'" -ErrorAction SilentlyContinue) {
            $status  = 'Ignorado'
            $detalhe = 'Usuário já existe'
        }
        elseif ($PSCmdlet.ShouldProcess($login, "Criar usuário na OU $($u.OU)")) {
            $senha = New-SenhaTemporaria

            $params = @{
                Name                  = "$($u.Nome) $($u.Sobrenome)"
                GivenName             = $u.Nome
                Surname               = $u.Sobrenome
                DisplayName           = "$($u.Nome) $($u.Sobrenome)"
                SamAccountName        = $login
                UserPrincipalName     = "$login@$Dominio"
                Department            = $u.Departamento
                Title                 = $u.Cargo
                Path                  = $u.OU
                AccountPassword       = (ConvertTo-SecureString $senha -AsPlainText -Force)
                ChangePasswordAtLogon = $true
                Enabled               = $true
            }
            New-ADUser @params -ErrorAction Stop

            if ($u.Grupos) {
                foreach ($grupo in ($u.Grupos -split ';' | Where-Object { $_.Trim() })) {
                    Add-ADGroupMember -Identity $grupo.Trim() -Members $login -ErrorAction Stop
                }
            }

            $status  = 'Criado'
            $detalhe = 'Senha temporária gerada; troca obrigatória no primeiro login'
            # A senha NÃO é gravada no log. Entregue-a ao usuário por um canal seguro.
            Write-Host "[$login] senha temporária: $senha" -ForegroundColor Yellow
        }
        else {
            $status  = 'Simulado'
            $detalhe = 'Executado com -WhatIf'
        }
    }
    catch {
        $status  = 'Erro'
        $detalhe = $_.Exception.Message
    }

    $resultados.Add([pscustomobject]@{
        Linha   = $linha
        Login   = $u.Login
        Status  = $status
        Detalhe = $detalhe
    })
}

$resultados | Export-Csv -Path $arquivoLog -NoTypeInformation -Encoding UTF8
$resultados | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize
Write-Host "Log salvo em: $arquivoLog"
