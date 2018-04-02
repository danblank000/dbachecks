$filename = $MyInvocation.MyCommand.Name.Replace(".Tests.ps1", "")

# Get all the info in the function
function Get-ClusterObject {
    [CmdletBinding()]
    param (
        [string]$Cluster
    )
    
    # needs the failover cluster module
    if (-not (Get-Module FailoverClusters)) {
        try {
            Import-Module FailoverClusters -ErrorAction Stop
        }
        catch {
            Stop-PSFFunction -Message "FailoverClusters module could not load - Please install the Failover Cluster module using Windows Features " -ErrorRecord $psitem
            return
        }
    }
    [pscustomobject]$return = @{ }
    $return.Cluster = (Get-Cluster -Name $cluster)
    $return.Nodes = (Get-ClusterNode -Cluster $cluster)
    $return.Resources = (Get-ClusterResource -Cluster $cluster)
    $return.Network = (Get-ClusterNetwork -Cluster $cluster)
    $return.Groups = (Get-ClusterGroup -Cluster $cluster)

    $return.AGs = $return.Resources.Where{ $psitem.ResourceType -eq 'SQL Server Availability Group' }
    $Ags = $return.AGs.Name
    $return.AvailabilityGroups = @{}
    #Add all the AGs
    foreach ($Ag in $ags ) {
        
        $return.AvailabilityGroups[$AG] = Get-DbaAvailabilityGroup -SqlInstance $AG -AvailabilityGroup $ag
    }

    Return $return
}

    # Grab some values
    $clusters = Get-DbcConfigValue app.clusters
    $skiplistener = Get-DbcConfigValue skip.hadr.listener.pingcheck
    $domainname = Get-DbcConfigValue domain.name
    $tcpport = Get-DbcConfigValue policy.hadr.tcpport

    #Check for Cluster config value
    if ($clusters.Count -eq 0) {
        Write-Warning "No Clusters to look at. Please use Set-DbcConfig -Name app.clusters to add clusters for checking"
        break
    }
    
    foreach ($cluster in $clusters) {
        # pick the name here for the output - we cant use it as we are accessing remotely
        $clusterName = (Get-Cluster -Name $cluster).Name
        Describe "Cluster $clusterName Health using Node $cluster" -Tags ClusterHealth, $filename {
        $return = Get-ClusterObject -Cluster $cluster
    
        Context "Cluster nodes for $clusterName" {
            $return.Nodes.ForEach{
                It "Node $($psitem.Name) should be up" {
                    $psitem.State | Should -Be 'Up' -Because 'Every node in the cluster should be available'
                }
            }
        }
        Context "Cluster resources for $clusterName" {
            $return.Resources.foreach{
                It "Resource $($psitem.Name) should be online" {
                    $psitem.State | Should -Be 'Online' -Because 'All of the cluster resources should be online'
                }
            }
        }
        Context "Cluster networks for $clusterName" {
            $return.Network.ForEach{
                It "$($psitem.Name) should be up" {
                    $psitem.State | Should -Be 'Up' -Because 'All of the CLuster Networks should be up'
                }
            }
        }
        
        Context "HADR status for $clusterName" {
            $return.Nodes.ForEach{
                It "HADR should be enabled on the node $($psitem.Name)" {
                    (Get-DbaAgHadr -SqlInstance $psitem.Name).IsHadrEnabled | Should -BeTrue -Because 'All of the nodes should have HADR enabled'
                }
            }
        }
        $Ags = $return.AGs.Name
        foreach($Name in $Ags) {
            $Ag = $return.AvailabilityGroups[$Name]
            
            Context "Cluster Connectivity for Availability Group $($AG.Name) on $cluster" {
                $AG.AvailabilityGroupListeners.ForEach{
                    $results = Test-DbaConnection -sqlinstance $_.Name
                    It "Listener $($results.SqlInstance) should be pingable" -skip:$skiplistener{
                        $results.IsPingable | Should -BeTrue -Because 'The listeners should be pingable'
                    }
                    It "Listener $($results.SqlInstance) should be able to connect with SQL" {
                        $results.ConnectSuccess | Should -BeTrue -Because 'The listener should process SQL commands successfully'
                    }
                    It "Listener $($results.SqlInstance) domain name should be $domainname" {
                        $results.DomainName | Should -Be $domainname -Because "$domainname is what we expect the domain name to be"
                    }
                    It "Listener $($results.SqlInstance) TCP port should be $tcpport" {
                        $results.TCPPort | Should -Be $tcpport -Because "$tcpport is what we said the TCP port should be"
                    }
                }

                $AG.AvailabilityReplicas.ForEach{
                    $results = Test-DbaConnection -sqlinstance $PsItem.Name
                    It "Replica $($results.SqlInstance) Should Be Pingable" -skip:$skiplistener{
                        $results.IsPingable | Should -BeTrue -Because 'Each replica should be pingable'
                    }
                    It "Replica $($results.SqlInstance) should be able to connect with SQL" {
                        $results.ConnectSuccess | Should -BeTrue -Because 'Each replica should be able to process SQL commands'
                    }
                    It "Replica $($results.SqlInstance) domain name should be $domainname" {
                        $results.DomainName | Should -Be $domainname -Because "$domainname is what we expect the domain name to be"
                    }
                    It "Replica $($results.SqlInstance) TCP port should be $tcpport" {
                        $results.TCPPort | Should -Be $tcpport -Because "$tcpport is what we said the TCP port should be"
                    }
                }
            }

            Context "Availability group status for $($AG.Name) on $clusterName on $cluster" {
                $AG.AvailabilityReplicas.ForEach{
                    It "$($psitem.Name) replica should not be in unknown availability mode" {
                        $psitem.AvailabilityMode | Should -Not -Be 'Unknown' -Because 'The replica should not be in unknown state'
                    }
                }
                $AG.AvailabilityReplicas.Where{ $psitem.AvailabilityMode -eq 'SynchronousCommit' }.ForEach{
                    It "$($psitem.Name) replica should be synchronised" {
                        $psitem.RollupSynchronizationState | Should -Be 'Synchronized' -Because 'The synchronous replica should be synchronised'
                    }
                }
                $AG.AvailabilityReplicas.Where{ $psitem.AvailabilityMode -eq 'ASynchronousCommit' }.ForEach{
                    It "$($psitem.Name) replica should be synchronising" {
                        $psitem.RollupSynchronizationState | Should -Be 'Synchronizing' -Because 'The asynchronous replica should be synchronizing '
                    }
                }
                $AG.AvailabilityReplicas.Where.ForEach{
                    It"$($psitem.Name) replica should be connected" {
                        $psitem.ConnectionState | Should -Be 'Connected' -Because 'The replica should be connected'
                    }
                }
            
            }
        
            Context "Database availability group status for $($AG.Name) on $clusterName" {
                $Primary = $ag.AvailabilityReplicas.Where{$_.Role -eq 'Primary'}.Name
                (Get-DbaAgDatabase -SqlInstance $Primary -AvailabilityGroup $Ag.Name).ForEach{
                    It "Database $($psitem.DatabaseName) should be synchronised on the primary replica $($psitem.Replica)" {
                        $psitem.SynchronizationState | Should -Be 'Synchronized' -Because 'The database on the primary replica should be synchronised'
                    }
                    It "Database $($psitem.DatabaseName) should be failover ready on the primary replica $($psitem.Replica)" {
                        $psitem.IsFailoverReady | Should -BeTrue  -Because 'The database on the primary replica should be ready to failover'
                    }
                    It "Database $($psitem.DatabaseName) should be joined on the primary replica $($psitem.Replica)" {
                        $psitem.IsJoined | Should -BeTrue  -Because 'The database on the primary replica should be joined to the availablity group'
                    }
                    It "Database $($psitem.DatabaseName) should not be suspended on the primary replica $($psitem.Replica)" {
                        $psitem.IsSuspended | Should -Be  $False  -Because 'The database on the primary replica should not be suspended'
                    }
                }
                $SecSync = $ag.AvailabilityReplicas.Where{$_.Role -eq 'Secondary' -and $_.AvailabilityMode -eq 'SynchronousCommit' }.name
                (Get-DbaAgDatabase -SqlInstance $SecSync -AvailabilityGroup $Ag.Name).ForEach{
                    It "Database $($psitem.DatabaseName) should be synchronised on the secondary replica $($psitem.Replica)" {
                        $psitem.SynchronizationState | Should -Be 'Synchronized'  -Because 'The database on the synchronous secondary replica should be synchronised'
                    }
                    It "Database $($psitem.DatabaseName) should be failover ready on the secondary replica $($psitem.Replica)" {
                        $psitem.IsFailoverReady | Should -BeTrue -Because 'The database on the synchronous secondary replica should be ready to failover'
                    }
                    It "Database $($psitem.DatabaseName) should be joined on the secondary replica $($psitem.Replica)" {
                        $psitem.IsJoined | Should -BeTrue -Because 'The database on the synchronous secondary replica should be joined to the availability group'
                    }
                    It "Database $($psitem.DatabaseName) should not be suspended on the secondary replica $($psitem.Replica)" {
                        $psitem.IsSuspended | Should -Be  $False -Because 'The database on the synchronous secondary replica should not be suspended'
                    }
                }
                $SecASync = $ag.AvailabilityReplicas.Where{$_.Role -eq 'Secondary' -and $_.AvailabilityMode -eq 'AsynchronousCommit' }.name
                if($SecASync){
                (Get-DbaAgDatabase -SqlInstance $SecASync -AvailabilityGroup $Ag.Name).ForEach{
                    It "Database $($psitem.DatabaseName) should be synchronising on the secondary as it is Async" {
                        $psitem.SynchronizationState | Should -Be 'Synchronizing' -Because 'The database on the asynchronous secondary replica should be synchronising'
                    }
                    It "Database $($psitem.DatabaseName) should be failover ready on the secondary replica $($psitem.Replica)" {
                        $psitem.IsFailoverReady | Should -BeTrue -Because 'The database on the asynchronous secondary replica should be ready to failover'
                    }
                    It "Database $($psitem.DatabaseName) should be joined on the secondary replica $($psitem.Replica)" {
                        $psitem.IsJoined | Should -BeTrue -Because 'The database on the asynchronous secondary replica should be joined to the availaility group'
                    }
                    It "Database $($psitem.DatabaseName) should not be suspended on the secondary replica $($psitem.Replica)" {
                        $psitem.IsSuspended | Should -Be  $False -Because 'The database on the asynchronous secondary replica should not be suspended'
                    }
                }
            }
            }
            
                $AG.AvailabilityReplicas.ForEach{
                    Context "Always On extended event status for replica $($psitem.Name) on $clusterName " {
                    $Xevents = Get-DbaXEsession -SqlInstance $psitem.Name
                    It "Replica $($psitem.Name) should have an extended event session called AlwaysOn_health" {
                        $Xevents.Name  | Should -Contain 'AlwaysOn_health' -Because 'The extended events session should exist'
                    }
                    It "Replica $($psitem.Name) Always On Health extended event session should be running" {
                        $Xevents.Where{ $_.Name -eq 'AlwaysOn_health' }.Status | Should -Be 'Running' -Because 'The extended event session will enable you to troubleshoot errors'
                    }
                    It "Replica $($psitem.Name) Always On Health extended event session should be set to auto start" {
                        $Xevents.Where{ $_.Name -eq 'AlwaysOn_health' }.AutoStart | Should -BeTrue  -Because 'The extended event session will enable you to troubleshoot errors'
                    }
                }
            }
        }
    }
}
       