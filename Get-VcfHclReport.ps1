<#
.SYNOPSIS
Retrieves hardware and firmware data from a vSphere cluster to check compliance with VCF 9.1 hardware compatibility lists (HCL).

.DESCRIPTION
This script connects to a vCenter server, targets a specific cluster, and extracts hardware, firmware, and driver information for Host Bus Adapters (HBAs), Network Interface Cards (NICs), Physical Storage Drives, Boot Devices, and TPM status on each ESXi host. The gathered data is then exported to a CSV file for analysis against the Broadcom HCL.

.REQUIREMENTS
* PowerShell 5.1 or later / PowerShell Core 7.x
* VMware PowerCLI 13.0 or later

.NOTES
Ensure you have appropriate permissions to connect to vCenter and execute commands on the ESXi hosts.
The resulting CSV will be saved in the directory where the script is executed.
#>

# =====================================================================
# Configuration Variables
# =====================================================================

# FQDN or IP address of the vCenter Server
$vCenterServer = "Enter the FQDN or IP of your vcenter here. Don't lead with http:// or https://"

# Name of the vSphere Cluster to target
$ClusterName = "vSAN Cluster" 

# Desired output filename for the CSV report
$OutputFile = "VCF_9.1_HCL_Report.csv" 

# =====================================================================
# Script Execution
# =====================================================================

# Load the VMware PowerCLI module if it's not already loaded
if (-not (Get-Module -Name VMware.PowerCLI -ErrorAction SilentlyContinue)) {
    Import-Module VMware.PowerCLI -ErrorAction Stop
}

# Prompt user for CEIP participation (Session scope only)
$ceipChoice = Read-Host "Do you want to participate in the VMware Customer Experience Improvement Program (CEIP)? (Y/N)"
if ($ceipChoice -match "^[Yy]$") {
    Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $true -Confirm:$false | Out-Null
    Write-Host "CEIP participation enabled for this session." -ForegroundColor Green
} elseif ($ceipChoice -match "^[Nn]$") {
    Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -Confirm:$false | Out-Null
    Write-Host "CEIP participation disabled for this session." -ForegroundColor Yellow
} else {
    Write-Host "Invalid choice. Proceeding with current CEIP settings." -ForegroundColor Yellow
}

# Check if output file exists and prompt for action
$ExportMode = "New"
if (Test-Path $OutputFile) {
    $fileChoice = Read-Host "The file '$OutputFile' already exists. Do you want to [A]ppend to it or create a [N]ew file? (A/N)"
    if ($fileChoice -match "^[Nn]$") {
        $OutputFile = Read-Host "Enter the new filename (e.g., VCF_Report_v2.csv)"
        if (-not $OutputFile.EndsWith(".csv")) {
            $OutputFile += ".csv"
        }
    } elseif ($fileChoice -match "^[Aa]$") {
        $ExportMode = "Append"
    } else {
        Write-Host "Invalid choice. Defaulting to creating a new file." -ForegroundColor Yellow
        $OutputFile = Read-Host "Enter the new filename (e.g., VCF_Report_v2.csv)"
        if (-not $OutputFile.EndsWith(".csv")) {
            $OutputFile += ".csv"
        }
    }
}

# Ignore self-signed certificate errors for this session only (no persistent changes)
Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null

Write-Host "Connecting to vCenter Server: $vCenterServer" -ForegroundColor Cyan
Connect-VIServer -Server $vCenterServer 

Write-Host "Retrieving Hosts in Cluster: $ClusterName" -ForegroundColor Cyan
$Hosts = Get-Cluster -Name $ClusterName | Get-VMHost

$Report = [System.Collections.Generic.List[PSObject]]::new()

# Capture cluster collection timestamp once
$collectionTimestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")

foreach ($vmHost in $Hosts) {
    Write-Host "Processing Host: $($vmHost.Name)" -ForegroundColor Yellow
    
    # Enable ESXi Shell/SSH temporarily if using Get-EsxCli
    $esxcli = Get-EsxCli -VMHost $vmHost -V2
    
    # Get Bios/Platform details
    $biosVersion = $vmHost.ExtensionData.Hardware.BiosInfo.BiosVersion
    $serverModel = $vmHost.Model
    $vendor = $vmHost.Manufacturer
    $cpuModel = $vmHost.ExtensionData.Summary.Hardware.CpuModel
    
    # Core counts & Memory
    $totalCores = $vmHost.ExtensionData.Hardware.CpuInfo.NumCpuCores
    $totalMemoryGB = [Math]::Round(($vmHost.ExtensionData.Hardware.MemorySize / 1GB), 2)
    
    # TPM details
    $tpmVersion = "Not Found/Unsupported"
    try {
        $tpmInfo = $vmHost.ExtensionData.Config.CertificateManagerInfo.TpmInfo
        if ($tpmInfo) {
            # Usually TPM 2.0 is reported if available for attestation
            $tpmVersion = "TPM Present (Check vCenter Attestation)" 
        }
    } catch {}

    # Gather Base Platform Info as a single entry (carries the collection timestamp)
    $Report.Add([PSCustomObject]@{
        CollectionTimestamp = $collectionTimestamp
        HostName            = $vmHost.Name
        Vendor              = $vendor
        ServerModel         = $serverModel
        BiosVersion         = $biosVersion
        CPUModel            = $cpuModel
        TotalCores          = $totalCores
        TotalMemoryGB       = $totalMemoryGB
        TPMVersion          = $tpmVersion
        Category            = "Host Platform"
        DeviceName          = "System Board"
        HardwareModel       = "System Board"
        CurrentFirmware     = $biosVersion
        CurrentDriver       = "N/A"
        VID                 = "N/A"
        DID                 = "N/A"
        SVID                = "N/A"
        SSID                = "N/A"
    })
    
    # Get PCI Devices and HBA Config for mapping
    $pciDevices = $vmHost.ExtensionData.Hardware.PciDevice
    $hbasConfig = $vmHost.ExtensionData.Config.StorageDevice.HostBusAdapter
    
    # Gather Fibre Channel HBA Information
    Write-Host "  Gathering FC HBA Info..."
    try {
        $fcHBAs = $esxcli.storage.san.fc.list.Invoke()
        foreach ($hba in $fcHBAs) {
            $vid = "N/A"; $did = "N/A"; $svid = "N/A"; $ssid = "N/A"
            $hbaConf = $hbasConfig | Where-Object { $_.Device -eq $hba.Adapter }
            if ($hbaConf) {
                $pciDev = $pciDevices | Where-Object { $_.Id -eq $hbaConf.Pci }
                if ($pciDev) {
                    $vid = "{0:x4}" -f $pciDev.VendorId
                    $did = "{0:x4}" -f $pciDev.DeviceId
                    $svid = "{0:x4}" -f $pciDev.SubVendorId
                    $ssid = "{0:x4}" -f $pciDev.SubDeviceId
                }
            }

            $Report.Add([PSCustomObject]@{
                CollectionTimestamp = "N/A"
                HostName            = $vmHost.Name
                Vendor              = $vendor
                ServerModel         = $serverModel
                BiosVersion         = $biosVersion
                CPUModel            = $cpuModel
                TotalCores          = $totalCores
                TotalMemoryGB       = $totalMemoryGB
                TPMVersion          = $tpmVersion
                Category            = "FC HBA"
                DeviceName          = $hba.Adapter
                HardwareModel       = $hba.ModelDescription
                CurrentFirmware     = $hba.FirmwareVersion
                CurrentDriver       = "$($hba.DriverName) $($hba.DriverVersion)"
                VID                 = $vid
                DID                 = $did
                SVID                = $svid
                SSID                = $ssid
            })
        }
    } catch {
        Write-Host "  No FC HBAs found or error retrieving data." -ForegroundColor Gray
    }
    
    # Gather SAS/SATA HBA Information (Smart Array Controllers)
    Write-Host "  Gathering SAS HBA Info..."
    try {
        $sasHBAs = $esxcli.storage.san.sas.list.Invoke()
        foreach ($hba in $sasHBAs) {
            $vid = "N/A"; $did = "N/A"; $svid = "N/A"; $ssid = "N/A"
            $hbaConf = $hbasConfig | Where-Object { $_.Device -eq $hba.DeviceName }
            if ($hbaConf) {
                $pciDev = $pciDevices | Where-Object { $_.Id -eq $hbaConf.Pci }
                if ($pciDev) {
                    $vid = "{0:x4}" -f $pciDev.VendorId
                    $did = "{0:x4}" -f $pciDev.DeviceId
                    $svid = "{0:x4}" -f $pciDev.SubVendorId
                    $ssid = "{0:x4}" -f $pciDev.SubDeviceId
                }
            }
            
            $Report.Add([PSCustomObject]@{
                CollectionTimestamp = "N/A"
                HostName            = $vmHost.Name
                Vendor              = $vendor
                ServerModel         = $serverModel
                BiosVersion         = $biosVersion
                CPUModel            = $cpuModel
                TotalCores          = $totalCores
                TotalMemoryGB       = $totalMemoryGB
                TPMVersion          = $tpmVersion
                Category            = "SAS HBA"
                DeviceName          = $hba.DeviceName
                HardwareModel       = $hba.ModelDescription
                CurrentFirmware     = $hba.FirmwareVersion
                CurrentDriver       = "$($hba.DriverName) $($hba.DriverVersion)"
                VID                 = $vid
                DID                 = $did
                SVID                = $svid
                SSID                = $ssid
            })
        }
    } catch {
        Write-Host "  No SAS HBAs found or error retrieving data." -ForegroundColor Gray
    }

    # Query Physical Storage Drives
    Write-Host "  Gathering Physical Storage Drives..."
    try {
        $disks = $esxcli.storage.core.device.list.Invoke()
        foreach ($disk in $disks) {
            # Skip CD ROMs and Datastore enclosures
            if ($disk.DeviceType -eq "Direct-Access" -or $disk.DeviceType -eq "Disk") {
                $Report.Add([PSCustomObject]@{
                    CollectionTimestamp = "N/A"
                    HostName            = $vmHost.Name
                    Vendor              = $vendor
                    ServerModel         = $serverModel
                    BiosVersion         = $biosVersion
                    CPUModel            = $cpuModel
                    TotalCores          = $totalCores
                    TotalMemoryGB       = $totalMemoryGB
                    TPMVersion          = $tpmVersion
                    Category            = "Physical Drive"
                    DeviceName          = $disk.Device
                    HardwareModel       = "$($disk.Vendor) $($disk.Model)"
                    CurrentFirmware     = $disk.Revision
                    CurrentDriver       = $disk.DriveType # e.g. flash or hdd
                    VID                 = "N/A"
                    DID                 = "N/A"
                    SVID                = "N/A"
                    SSID                = "N/A"
                })
            }
        }
    } catch {
        Write-Warning "Could not query physical drives on $($vmHost.Name)"
    }

    # Identify Boot Device
    Write-Host "  Identifying Boot Device..."
    try {
        $bootbank = $esxcli.system.boot.device.get.Invoke()
        if ($bootbank.BootFilesystemUUID) {
            $Report.Add([PSCustomObject]@{
                CollectionTimestamp = "N/A"
                HostName            = $vmHost.Name
                Vendor              = $vendor
                ServerModel         = $serverModel
                BiosVersion         = $biosVersion
                CPUModel            = $cpuModel
                TotalCores          = $totalCores
                TotalMemoryGB       = $totalMemoryGB
                TPMVersion          = $tpmVersion
                Category            = "Boot Volume"
                DeviceName          = $bootbank.BootFilesystemUUID
                HardwareModel       = "Local Boot Bank"
                CurrentFirmware     = "N/A"
                CurrentDriver       = "N/A"
                VID                 = "N/A"
                DID                 = "N/A"
                SVID                = "N/A"
                SSID                = "N/A"
            })
        }
    } catch {
         Write-Warning "Could not identify boot device on $($vmHost.Name)"
    }

    # Query Physical NICs
    Write-Host "  Gathering NIC Info..."
    $nics = $vmHost | Get-VMHostNetworkAdapter -Physical
    foreach ($nic in $nics) {
        $vid = "N/A"; $did = "N/A"; $svid = "N/A"; $ssid = "N/A"
        $pciAddress = $nic.ExtensionData.Pci
        if (-not $pciAddress) { $pciAddress = $nic.PciPosition }
        
        if ($pciAddress) {
            $pciDev = $pciDevices | Where-Object { $_.Id -eq $pciAddress }
            if ($pciDev) {
                $vid = "{0:x4}" -f $pciDev.VendorId
                $did = "{0:x4}" -f $pciDev.DeviceId
                $svid = "{0:x4}" -f $pciDev.SubVendorId
                $ssid = "{0:x4}" -f $pciDev.SubDeviceId
            }
        }
        
        try {
            $nicDetails = $esxcli.network.nic.get.Invoke(@{nicname = $nic.DeviceName})
            
            # Fix empty HardwareModel parsing
            $hwModel = $nicDetails.Description
            if ([string]::IsNullOrWhiteSpace($hwModel)) {
                $hwModel = "N/A"
            }
            
            $Report.Add([PSCustomObject]@{
                CollectionTimestamp = "N/A"
                HostName            = $vmHost.Name
                Vendor              = $vendor
                ServerModel         = $serverModel
                BiosVersion         = $biosVersion
                CPUModel            = $cpuModel
                TotalCores          = $totalCores
                TotalMemoryGB       = $totalMemoryGB
                TPMVersion          = $tpmVersion
                Category            = "Network Adapter"
                DeviceName          = $nic.DeviceName
                HardwareModel       = $hwModel
                CurrentFirmware     = $nicDetails.DriverInfo.FirmwareVersion
                CurrentDriver       = "$($nicDetails.DriverInfo.Driver) $($nicDetails.DriverInfo.Version)"
                VID                 = $vid
                DID                 = $did
                SVID                = $svid
                SSID                = $ssid
            })
        } catch {
            Write-Warning "Could not query NIC $($nic.DeviceName) on $($vmHost.Name)"
        }
    }
}

Write-Host "Disconnecting from vCenter..." -ForegroundColor Cyan
Disconnect-VIServer -Server $vCenterServer -Confirm:$false

Write-Host "Exporting data to $OutputFile" -ForegroundColor Green

# Prepare parameters for cross-version Export-Csv compatibility
$csvParams = @{
    Path = $OutputFile
}

# Apply -NoTypeInformation only when running on Windows PowerShell 5.1 or earlier
if ($PSVersionTable.PSVersion.Major -lt 6) {
    $csvParams['NoTypeInformation'] = $true
}

if ($ExportMode -eq "Append") {
    $csvParams['Append'] = $true
}

$Report | Export-Csv @csvParams

Write-Host "Script execution completed." -ForegroundColor Green
