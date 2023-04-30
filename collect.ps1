#!/usr/bin/env pwsh

$ErrorActionPreference = "Stop"
Set-PSDebug -Strict

$vCenter = $env:VCENTER
$vCenterUser = $env:VCENTER_USER
$vCenterPassword = $env:VCENTER_PASSWORD

$InfluxListener = $env:INFLUXDB_LISTENER
$InfluxStorageDeviceBucket = $env:INFLUXDB_STORAGE_DEVICE_BUCKET
$InfluxNvmeBucket = $env:INFLUXDB_NVME_BUCKET
"Metrics will be logged to buckets $InfluxStorageDeviceBucket and $InfluxNvmeBucket at $InfluxListener" | Write-Information

$IntervalSeconds = $env:INTERVAL_SECONDS

function ConvertFrom-EsxCliValue {
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string] $Value
    )

    # parse int or hex
    if ($Value -match '^\d+$') {
        return [Int64]::Parse($Value)
    }
    if ($Value -match '^0x[0-9a-fA-F]+$') {
        return [Int64]::Parse($Value.Substring(2), [System.Globalization.NumberStyles]::HexNumber)
    }

    # parse boolean
    if ($Value -eq 'true') {
        return $true
    }
    if ($Value -eq 'false') {
        return $false
    }
 
    return $Value
}

function Format-InfluxLineKey {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        $Key
    )

    # escape , = " \ and space
    $Key = $Key -replace ',', '\,'
    $Key = $Key -replace '=', '\='
    $Key = $Key -replace '"', '\"'
    $Key = $Key -replace '\\', '\\\\'
    $Key = $Key -replace ' ', '\ '

    return $Key
}

function Format-InfluxLineValue {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        $Value
    )

    # suffix i for integer
    if ($Value -is [Int64]) {
        return "${Value}i"
    }

    # normalize boolean
    if ($Value -is [bool]) {
        if ($Value) {
            return "true"
        }
        else {
            return "false"
        }
    }

    # escape " and \
    $Value = $Value -replace '"', '\"'
    $Value = $Value -replace '\\', '\\'

    # quote string
    return "`"$Value`""
}

function Format-InfluxLine {
    param (
        [Parameter(Mandatory = $true)]
        [string] $Measurement,

        [Parameter(Mandatory = $true)]
        [string] $Bucket,

        [hashtable] $Tags,
        
        [Parameter(Mandatory = $true)]
        $Value
    )

    # measurement, $tag=$value, $tag=$value value=$value timestamp

    $Line = $Measurement | Format-InfluxLineKey
    $Line += ",bucket=$Bucket"
    foreach ($tag in $Tags.GetEnumerator() | Where-Object { $null -ne $_.Value -and $_.Value -ne '' }) {
        $Line += ",$($tag.Name | Format-InfluxLineKey)=$($tag.Value | Format-InfluxLineKey)"
    }
    $Line += " value=$($Value | Format-InfluxLineValue)"
    return $Line
}

function Export-AllMetrics {
    $lines = @()

    foreach ($cluster in Get-Cluster) {
        $clusterName = $cluster.Name

        foreach ($vmHost in $cluster | Get-VMHost | Where-Object { $_.ConnectionState -eq 'Connected' }) {
            $vmHostName = $vmHost.Name
            $esxCli = Get-EsxCli -VMHost $vmHost -V2

            foreach ($device in $esxCli.storage.core.device.list.Invoke()) {
                $storageDeviceTags = @{
                    host    = $vmHostName;
                    cluster = $clusterName;
                    device  = $device.device;
                    model   = $device.Model;
                }
                $isOffline = $device.IsOffline
                $line = Format-InfluxLine -Bucket $InfluxStorageDeviceBucket -Measurement "IsOffline" -Tags $storageDeviceTags -Value $isOffline
                $lines += $line

                if ($isOffline) {
                    continue
                }

                $smart = $esxCli.storage.core.device.smart.get.Invoke(@{ 'devicename' = $device.device })
                foreach ($property in $smart.PSObject.Properties) {
                    $measurement = $property.Name
                    $value = $property.Value | ConvertFrom-EsxCliValue 
                    $line = Format-InfluxLine -Bucket $InfluxStorageDeviceBucket -Measurement $measurement -Tags $storageDeviceTags -Value $value
                    $lines += $line
                }
            }

            foreach ($adapter in $esxCli.nvme.adapter.list.Invoke()) {
                $adapterName = $adapter.Adapter
                $aqn = $adapter.AdapterQualifiedName

                $device = $esxCli.nvme.device.get.Invoke(@{ 'adapter' = $adapterName })
                $model = $device.ModelNumber
                $serialNumber = $device.SerialNumber
            
                $smart = $esxCli.nvme.device.log.smart.get.Invoke(@{ 'adapter' = $adapterName })
                foreach ($property in $smart.PSObject.Properties) {
                    $measurement = $property.Name
                    $value = $property.Value | ConvertFrom-EsxCliValue 
                    $tags = @{
                        host   = $vmHostName;
                        aqn    = $aqn;
                        model  = $model;
                        serial = $serialNumber;
                    }
                    $line = Format-InfluxLine -Bucket $InfluxNvmeBucket -Measurement $measurement -Tags $tags -Value $value
                    $lines += $line
                }
            }
        }
    }

    return $lines
}

while ($true) {
    $time = Measure-Command {
        $defaultviserver = Get-Variable 'defaultviserver' -Scope Global -ErrorAction SilentlyContinue
        if ($null -eq $defaultviserver -or $defaultviserver.IsConnected -eq $false) {
            Connect-VIServer $vCenter -User $vCenterUser -Password $vCenterPassword -Force
        }

        $lines = Export-AllMetrics
        $body = $lines | Join-String -Separator "`n"
        $response = Invoke-WebRequest -Uri $InfluxListener -Method Post -ContentType 'text/plain; charset=utf-8' -Body $body
        if ($response.StatusCode -eq 204) {
            $response | Write-Verbose
        }
        else {
            $response | Write-Error
        }
    }
    "$(Get-Date -Format "o"): $($lines.Length) metrics exported in $($time.TotalSeconds) seconds" | Write-Debug
    Start-Sleep -Seconds $IntervalSeconds
}
