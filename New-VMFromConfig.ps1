param([string]$config)
#read from xml 
[xml]$vmconfig = Get-Content "\\domain.local\repo$\$config.config"
$VM = $VMConfig.VM

[xml]$DCConfig = Get-Content "\\domain.local\repo$\datacenters.config"
$DC = $DCConfig.Datacenters.Datacenter | where {$_.Name -eq $VM.Datacenter}

#admin creds to domain/vsphere
if(!$VIServer -or !$cred){
    do{
    $cred = get-credential
    $VIServer = connect-viserver $DC.IP -Credential $cred
    }While(!$VIServer)
}

#what VM Host should it use, if not defined by vmconfig, use dcconfig default
if($VM.Host -ne "default"){$VMHost = Get-VMHost $VM.Host}
else{$ResourcePool = Get-Cluster $DC.Cluster | Get-ResourcePool -Name Resources}

#what datastore should it use, if not defined by vmconfig, use lease used
if($VM.Datastore -ne "default"){$Datastore = Get-Datastore -server $VIServer -Name $VM.Datastore}
else{$Datastore = $DC.Defaults.Datastore}

#take VM.OSVersion and VM.desktop and combine to pull the appropriate template. should be either GUI or Core. Only 2016 currently supported.
if($VM.Desktop -eq "Yes"){$Template = Get-Template -Server $VIServer -Name ($DC.Template.GUI)}
else{$Template = Get-Template -Server $VIServer -Name ($DC.Template.Core)}

$VMName = $VM.Name

#get the oscustomization spec i've pre-created for joining domain
$oscust = get-oscustomizationspec "domain.local"

#create vm
    if(New-VM -Name $VM.Name -Template $template -ResourcePool $resourcePool -VMHost $VMHost -Datastore $Datastore -OSCustomizationSpec $oscust -confirm){

        #update vm hardware
        Set-VM $VM.Name -MemoryGB $VM.MemoryGB -NumCPU $VM.NumCPU -Confirm:$false
        Get-HardDisk $VM.Name | Set-HardDisk -CapacityGB $VM.DiskGB -Confirm:$false

        #pre-create the ad object so it joins the domain in the correct OU (change to staging OU, or let xml define)
        New-ADComputer -Name $VM.Name -DNSHostName "$($VM.name).domain.local" -Path "OU=$($VM.OU),OU=Servers,DC=Domain,DC=Local" -Credential $cred

        #power on
        Start-VM $VM.Name
   
        #wait for boot
        echo "Waiting for boot and domain join..."
        do{
            start-sleep 5
            echo waiting...
        }While(!Test-Path "\\$($VM.name)\c$")
        
        #extend drive
        Invoke-Command -ComputerName "$($vm.name).domain.local" -ScriptBlock {'RESCAN','SELECT Volume C', 'EXTEND', 'EXIT' | DiskPart.exe} -Credential $cred 

        #update vmtools
        Update-Tools $VM.Name -NoReboot

        #copy config to the machine for DSC
        Copy-Item "\\domain.local\repo$\$config.config" "\\$($vm.name).domain.local\C$\Config\$($vm.name).config" -Force -PassThru

        #set Static IP
        Invoke-Command -ComputerName "$($vm.name).domain.local" -ScriptBlock {
            param($IP, $Subnet, $Gateway, $PrimaryDNS, $SecondaryDNS)
            netsh interface ip set address "Ethernet0" static $IP $Subnet $Gateway
            netsh interface ip set dns "Ethernet0" static $PrimaryDNS
            netsh interface ip add dns "Ethernet0" $SecondaryDNS index=2
            ipconfig /registerdns
            Set-TimeZone "Pacific Daylight Time"
        } -argumentlist $VM.Network.IP,$VM.Network.Subnet,$VM.Network.Gateway,$VM.Network.PrimaryDNS,$VM.Network.SecondaryDNS
        ipconfig /flushdns

        #check if not the standard PROD 
        if($VM.Network.VLAN -ne "Prod"){
            Get-VM $VM.Name | Get-NetworkAdapter | Set-NetworkAdapter -NetworkName $DC.VLAN.($VM.Network.VLAN) -Confirm $false
        }

    }
   

#close our session
$VIServer = ""
Disconnect-VIServer -Confirm:$false
