﻿using module ..\Include.psm1

param(
    [TimeSpan]$StatSpan,
    [PSCustomObject]$Config #to be removed
)

$PoolName = Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName

#Pool currenctly allows payout in BTC only
$Payout_Currencies = @("BTC") | Where-Object { $Config.Pools.$PoolName.Wallets.$_ }
if (-not $Payout_Currencies) {
    Write-Log -Level Verbose "Cannot mine on pool ($PoolName) - no wallet address specified. "
    return
}

$PoolRegions = "eu", "jp", "usa"
$PoolHost = "nicehash.com"
$PoolAPIUri = "https://api2.nicehash.com/main/api/v2/public/simplemultialgo/info/"
$PoolAPIAlgodetailsUri = "https://api2.nicehash.com/main/api/v2/mining/algorithms/"

$RetryCount = 3
$RetryDelay = 2
while (-not ($APIResponse) -and $RetryCount -gt 0) {
    try {
        if (-not $APIResponse) {
            $APIResponse = Invoke-RestMethod $PoolAPIUri -TimeoutSec 3 -UseBasicParsing -Headers @{"Cache-Control" = "no-cache" }
        }
        if (-not $APIResponseAlgoDetails) {
            $APIResponseAlgoDetails = Invoke-RestMethod $PoolAPIAlgodetailsUri -TimeoutSec 3 -UseBasicParsing -Headers @{"Cache-Control" = "no-cache" }
        }
    }
    catch {
        Start-Sleep -Seconds $RetryDelay
        $RetryCount--
    }
}

if (-not $APIResponse) {
    Write-Log -Level Warn "Pool API ($PoolName) has failed. "
    return
}
if (-not $APIResponseAlgoDetails) {
    Write-Log -Level Warn "Pool API ($PoolName) has failed. "
    return
}

if ($APIResponse.miningAlgorithms.count -le 1) {
    Write-Log -Level Warn "Pool API ($PoolName) returned nothing. "
    return
}
if ($APIResponseAlgoDetails.miningAlgorithms.count -le 1) {
    Write-Log -Level Warn "Pool API ($PoolName) returned nothing. "
    return
}

if ($Config.Pools.$PoolName.IsInternalWallet) { $Fee = 0.01 } else { $Fee = 0.03 }

Write-Log -Level Verbose "Processing pool data ($PoolName). "
$APIResponse.miningAlgorithms | ForEach-Object { $Algorithm = $_.Algorithm; $_ | Add-Member -force @{algodetails = $APIResponseAlgoDetails.miningAlgorithms | Where-Object { $_.Algorithm -eq $Algorithm } } }
$APIResponse.miningAlgorithms | Where-Object { $_.paying -gt 0 } <# algos paying 0 fail stratum #> | ForEach-Object {

    $Port = $_.algodetails.port
    $Algorithm = $_.algorithm.ToLower()
    $Algorithm_Norm = Get-Algorithm $Algorithm
    $CoinName = ""

    if ($Algorithm -eq "Beam") { $Algorithm_Norm = "EquihashR15050" } #temp fix
    if ($Algorithm -eq "Decred") { $Algorithm_Norm = "DecredNiceHash" } #temp fix
    if ($Algorithm -eq "Mtp") { $Algorithm_Norm = "MtpNiceHash" } #temp fix
    if ($Algorithm -eq "Sia") { $Algorithm_Norm = "SiaNiceHash" } #temp fix

    $Divisor = 100000000

    $Stat = Set-Stat -Name "$($PoolName)_$($Algorithm_Norm)_Profit" -Value ([Double]$_.paying / $Divisor) -Duration $StatSpan -ChangeDetection $true

    $PoolRegions | ForEach-Object {
        $Region = $_
        $Region_Norm = Get-Region $Region

        $Payout_Currencies | ForEach-Object {
            [PSCustomObject]@{
                Algorithm     = $Algorithm_Norm
                CoinName      = $CoinName
                Price         = $Stat.Live
                StablePrice   = $Stat.Week
                MarginOfError = $Stat.Week_Fluctuation
                Protocol      = "stratum+tcp"
                Host          = "$Algorithm.$Region.$PoolHost"
                Port          = $Port
                User          = "$($Config.Pools.$PoolName.Wallets.$_).$($Config.Pools.$PoolName.Worker)"
                Pass          = "x"
                Region        = $Region_Norm
                SSL           = $false
                Updated       = $Stat.Updated
                Fee           = $Fee
                PayoutScheme  = "PPLNS"
            }
            [PSCustomObject]@{
                Algorithm     = $Algorithm_Norm
                CoinName      = $CoinName
                Price         = $Stat.Live
                StablePrice   = $Stat.Week
                MarginOfError = $Stat.Week_Fluctuation
                Protocol      = "stratum+ssl"
                Host          = "$Algorithm.$Region.$PoolHost"
                Port          = $Port
                User          = "$($Config.Pools.$PoolName.Wallets.$_).$($Config.Pools.$PoolName.Worker)"
                Pass          = "x"
                Region        = $Region_Norm
                SSL           = $true
                Updated       = $Stat.Updated
                Fee           = $Fee
                PayoutScheme  = "PPLNS"
            }
        }
    }
}
