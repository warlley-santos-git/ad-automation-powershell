<#
.SYNOPSIS
    Gera relatório de contas inativas no Active Directory e, opcionalmente, desabilita.

.DESCRIPTION
    Lista usuários habilitados sem login há mais de N dias (padrão: 90),
    exporta um CSV com os dados e, se -Desabilitar for usado, desabilita as contas
    e move para uma OU de quarentena. Sempre teste antes com -WhatIf.

.PARAMETER Dias
    Quantidade de dias sem login para considerar a conta inativa. Padrão: 90.

.PARAMETER BaseOU
    OU onde procurar. Se vazio, procura no domínio inteiro.

.PARAMETER Desabilitar
    Desabilita as contas encontradas.

.PARAMETER OUQuarentena
    OU para onde mover as contas desabilitadas (opcional).

.EXAMPLE
    .\Relatorio-ContasInativas.ps1 -Dias 90

.EXAMPLE
    .\Relatorio-ContasInativas.ps1 -Dias 120 -Desabilitar -OUQuarentena "OU=Inativos,DC=lab,DC=local" -WhatIf

.NOTES
    LastLogonDate é replicado entre controladores a cada ~14 dias, então o
    resultado é aproximado. Serve bem para relatórios de higiene de contas.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(1, 3650)]
    [int]$Dias = 90,

    [string]$BaseOU,

    [switch]$Desabilitar,

    [string]$OUQuarentena,

    [string]$PastaSaida = ".\relatorios"
)

Import-Module ActiveDirectory -ErrorAction Stop

if (-not (Test-Path $PastaSaida)) { New-Item -ItemType Directory -Path $PastaSaida | Out-Null }

$dataLimite = (Get-Date).AddDays(-$Dias)
$props = 'LastLogonDate','WhenCreated','Department','Title','Description'

$busca = @{
    Filter     = 'Enabled -eq $true'
    Properties = $props
}
if ($BaseOU) { $busca.SearchBase = $BaseOU }

$inativos = Get-ADUser @busca | Where-Object {
    # Nunca logou (e foi criada antes do limite) ou último login antes do limite
    ($null -eq $_.LastLogonDate -and $_.WhenCreated -lt $dataLimite) -or
    ($_.LastLogonDate -and $_.LastLogonDate -lt $dataLimite)
}

$relatorio = $inativos | Sort-Object LastLogonDate | Select-Object `
    SamAccountName,
    Name,
    Department,
    Title,
    @{ n = 'UltimoLogin';   e = { if ($_.LastLogonDate) { $_.LastLogonDate.ToString('dd/MM/yyyy') } else { 'Nunca' } } },
    @{ n = 'DiasSemLogin';  e = { if ($_.LastLogonDate) { [int]((Get-Date) - $_.LastLogonDate).TotalDays } else { $null } } },
    @{ n = 'CriadaEm';      e = { $_.WhenCreated.ToString('dd/MM/yyyy') } },
    DistinguishedName

$arquivo = Join-Path $PastaSaida ("contas-inativas_{0}dias_{1:yyyyMMdd}.csv" -f $Dias, (Get-Date))
$relatorio | Export-Csv -Path $arquivo -NoTypeInformation -Encoding UTF8 -Delimiter ';'

Write-Host ("{0} contas sem login há mais de {1} dias." -f @($relatorio).Count, $Dias)
Write-Host "Relatório: $arquivo"

if ($Desabilitar) {
    foreach ($conta in $inativos) {
        if ($PSCmdlet.ShouldProcess($conta.SamAccountName, 'Desabilitar conta')) {
            $nota = "Desabilitada por inatividade ($Dias dias) em {0:dd/MM/yyyy}" -f (Get-Date)
            Disable-ADAccount -Identity $conta
            Set-ADUser -Identity $conta -Description $nota
            if ($OUQuarentena) {
                Move-ADObject -Identity $conta.DistinguishedName -TargetPath $OUQuarentena
            }
        }
    }
}
