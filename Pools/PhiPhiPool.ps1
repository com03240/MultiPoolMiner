﻿using module ..\Include.psm1

param(
    [TimeSpan]$StatSpan,
    [PSCustomObject]$Config
)

$Name = Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName

if (-not ($Config.Pools.$Name.Wallets | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name) -ne "BTC") {
    Write-Log -Level Verbose "Cannot mine on pool ($Name) - no wallet address specified. "
    return
}

$PoolRegions = "asia", "eu", "us"
$PoolAPIStatusUri = "http://www.phi-phi-pool.com/api/status"
$PoolAPICurrenciesUri = "http://www.phi-phi-pool.com/api/currencies"

$RetryCount = 3
$RetryDelay = 2
while (-not ($APIStatusRequest -and $APICurrenciesRequest) -and $RetryCount -gt 0) {
    try {
        if (-not $APIStatusRequest) {$APIStatusRequest = Invoke-RestMethod $PoolAPIStatusUri -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop}
        if (-not $APICurrenciesRequest) {$APICurrenciesRequest  = Invoke-RestMethod $PoolAPICurrenciesUri -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop}
    }
    catch {
        Start-Sleep -Seconds $RetryDelay
        $RetryCount--        
    }
}

if (-not ($APIStatusRequest -and $APICurrenciesRequest)) {
    Write-Log -Level Warn "Pool API ($Name) has failed. "
    return
}

if (($APIStatusRequest | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Measure-Object Name).Count -lt 1) {
    Write-Log -Level Warn "Pool API ($Name) [StatusUri] returned nothing. "
    return
}

if (($APICurrenciesRequest | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Measure-Object Name).Count -lt 1) {
    Write-Log -Level Warn "Pool API ($Name) [CurrenciesUri] returned nothing. "
    return
}

#Pool does not do auto conversion to BTC
$Payout_Currencies = @($APICurrenciesRequest | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name) | Where-Object {$Config.Pools.$Name.Wallets.$_} | Sort-Object -Unique
if (-not $Payout_Currencies) {
    Write-Log -Level Verbose "Cannot mine on pool ($Name) - no wallet address specified. "
    return
}

$APICurrenciesRequest | Get-Member -MemberType NoteProperty -ErrorAction Ignore | Select-Object -ExpandProperty Name | Where-Object {$APICurrenciesRequest.$_.hashrate -gt 0} | Foreach-Object {
 
    $Algorithm = $APICurrenciesRequest.$_.algo

    # Not all algorithms are always exposed in API
    if ($APIStatusRequest.$Algorithm) {
    
        $APICurrenciesRequest.$_ | Add-Member Symbol $_ -ErrorAction SilentlyContinue

        $CoinName       = Get-CoinName $APICurrenciesRequest.$_.name
        $Algorithm_Norm = Get-AlgorithmFromCoinName $CoinName
        if (-not $Algorithm_Norm) {$Algorithm_Norm = Get-Algorithm $Algorithm}
        $PoolHost       = "phi-phi-pool.com"
        $Port           = $APICurrenciesRequest.$_.port
        $MiningCurrency = $APICurrenciesRequest.$_.symbol
        $Workers        = $APICurrenciesRequest.$_.workers
        $Fee            = $APIStatusRequest.$Algorithm.Fees / 100

        $Divisor = 1000000000 * [Double]$APIStatusRequest.$Algorithm.mbtc_mh_factor

        $Stat = Set-Stat -Name "$($Name)_$($CoinName)_Profit" -Value ([Double]$APICurrenciesRequest.$_.estimate / $Divisor) -Duration $StatSpan -ChangeDetection $true

        $PoolRegions | ForEach-Object {
            $Region = $_
            $Region_Norm = Get-Region $Region

            [PSCustomObject]@{
                Algorithm      = $Algorithm_Norm
                CoinName       = $CoinName
                Price          = $Stat.Live
                StablePrice    = $Stat.Week
                MarginOfError  = $Stat.Week_Fluctuation
                Protocol       = "stratum+tcp"
                Host           = "$Region.$PoolHost"
                Port           = $Port
                User           = $Config.Pools.$Name.Wallets.$MiningCurrency
                Pass           = "c=$MiningCurrency"
                Region         = $Region_Norm
                SSL            = $false
                Updated        = $Stat.Updated
                Fee            = $Fee
                Workers        = [Int]$Workers
                MiningCurrency = $MiningCurrency
            }
        }
    }
}