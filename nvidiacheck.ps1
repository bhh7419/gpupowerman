$MaxTemp=75
$SlowBoost=70
$LoadTreshold=10

$NvidiaCards=@()

function Start_SubProcess {
    param(
        [Parameter(Mandatory = $true)]
        [String]$FilePath,
        [Parameter(Mandatory = $false)]
        [String]$ArgumentList = "",
        [Parameter(Mandatory = $false)]
        [String]$WorkingDirectory = ""

    )

    $Job = Start-Job -ArgumentList $PID, $FilePath, $ArgumentList, $WorkingDirectory {
        param($ControllerProcessID, $FilePath, $ArgumentList, $WorkingDirectory)

        $ControllerProcess = Get-Process -Id $ControllerProcessID
        if ($ControllerProcess -eq $null) {return}

        $ProcessParam = @{}
        $ProcessParam.Add("FilePath", $FilePath)
        $ProcessParam.Add("WindowStyle", 'Minimized')
        if ($ArgumentList -ne "") {$ProcessParam.Add("ArgumentList", $ArgumentList)}
        if ($WorkingDirectory -ne "") {$ProcessParam.Add("WorkingDirectory", $WorkingDirectory)}
        $Process = Start-Process @ProcessParam -PassThru
        if ($Process -eq $null) {
            [PSCustomObject]@{ProcessId = $null}
            return
        }

        [PSCustomObject]@{ProcessId = $Process.Id; ProcessHandle = $Process.Handle}

        $ControllerProcess.Handle | Out-Null
        $Process.Handle | Out-Null

        do {if ($ControllerProcess.WaitForExit(1000)) {$Process.CloseMainWindow() | Out-Null}}
        while ($Process.HasExited -eq $false)
    }

    do {Start-Sleep 1; $JobOutput = Receive-Job $Job}
    while ($JobOutput -eq $null)

    $Process = Get-Process | Where-Object Id -EQ $JobOutput.ProcessId
    $Process.Handle | Out-Null
    $Process
}

Function Timed_ReadKb{   
    param(
        [Parameter(Mandatory = $true)]
        [int]$secondsToWait,
        [Parameter(Mandatory = $true)]
        [array]$ValidKeys

    )

    $Loopstart=get-date 
    $KeyPressed=$null    

    while ((NEW-TIMESPAN $Loopstart (get-date)).Seconds -le $SecondsToWait -and $ValidKeys -notcontains $KeyPressed){
        if ($host.ui.RawUi.KeyAvailable) {
                    $key = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyUp")
                    $KeyPressed=$Key.character
                    while ($Host.UI.RawUI.KeyAvailable)  {$host.ui.RawUi.Flushinputbuffer()} #keyb buffer flush
                    
                    }

         start-sleep -m 30            


   }  

   $KeyPressed
}

function get-gpu-information {
     #NVIDIA DEVICES
        $GpuId=0
        invoke-expression "./nvidia-smi.exe --query-gpu=uuid,gpu_name,utilization.gpu,utilization.memory,temperature.gpu,power.draw,power.limit,fan.speed,pstate,clocks.current.graphics,clocks.current.memory,power.max_limit,power.default_limit,power.min_limit  --format=csv,noheader"  | ForEach-Object {
    
                    $SMIresultSplit = $_ -split (",")   
                    $CurrentCard = $NvidiaCards | Where-Object uuid -eq $SMIresultSplit[0]
                    if ($CurrentCard -eq $null) {
                      $NvidiaCards +=[pscustomObject]@{
                                id                 = $GpuId
                                uuid               = $SMIresultSplit[0]
                                gpu_name           = $SMIresultSplit[1] 
                                utilization_gpu    = [int]($SMIresultSplit[2].Replace("%",""))
                                utilization_memory = $SMIresultSplit[3]
                                temperature_gpu    = [int]($SMIresultSplit[4])
                                power_draw         = $SMIresultSplit[5].Replace("W","")
                                power_limit        = [int]($SMIresultSplit[6].Replace("W",""))
                                FanSpeed           = $SMIresultSplit[7]
                                pstate             = $SMIresultSplit[8]
                                ClockGpu           = $SMIresultSplit[9]
                                ClockMem           = $SMIresultSplit[10]
                                Power_MaxLimit     = [int]($SMIresultSplit[11] -replace 'W','')
                                Power_DefaultLimit = [int]($SMIresultSplit[12] -replace 'W','')
                                Power_MinLimit     = [int]($SMIresultSplit[13] -replace 'W','')
                                LastRepTime        = (Get-Date)
                                LowLoad            = $null
                                LowLoadStamp       = $null
                                Power_LimitPercent = 0 
                                PowerChange        = "No"
                      }
                    } else {
                        $CurrentCard.id                 = $GpuId
                        $CurrentCard.utilization_gpu    = [int]($SMIresultSplit[2].Replace("%",""))
                        $CurrentCard.utilization_memory = $SMIresultSplit[3]
                        $CurrentCard.temperature_gpu    = [int]($SMIresultSplit[4])
                        $CurrentCard.power_draw         = $SMIresultSplit[5].Replace("W","")
                        $CurrentCard.power_limit        = [int]($SMIresultSplit[6].Replace("W",""))
                        $CurrentCard.FanSpeed           = $SMIresultSplit[7]
                        $CurrentCard.pstate             = $SMIresultSplit[8]
                        $CurrentCard.ClockGpu           = $SMIresultSplit[9]
                        $CurrentCard.ClockMem           = $SMIresultSplit[10]
			$CurrentCard.LastRepTime        = (GetDate)
			$CurrentCard.PowerChange        = "No"
                    }
                    $CurrentCard = $NvidiaCards | Where-Object uuid -eq $SMIresultSplit[0]
                    $CurrentCard.Power_limitpercent = ([math]::Floor(($CurrentCard.power_limit*100) / $CurrentCard.Power_DefaultLimit))
                    if ($CurrentCard.utilization_gpu -lt $LoadTreshold) {
                        if ($CurrentCard.LowLoad -ne $true) {
                           $CurrentCard.LowLoad = $true
                          if ($CurrentCard.LowLoadStamp -eq $null) {
                             $CurrentCard.LowLoadStamp = $CurrentCard.LastRepTime
                          }
                        }   
                      } else {
                        $CurrentCard.LowLoad = $false
                        $CurrentCard.LowLoadStamp = $null
                      }
                     [string]$cmd = "./nvidia-smi.exe"
                     if ($CurrentCard.pstate = "P2") {
                       if ($CurrentCard.utilization_gpu -gt $LoadTreshold) {
                         if ($CurrentCard.temperature_gpu -gt $MaxTemp + ($MaxTemp - $SlowBoost) -And $CurrentCard.power_limit -gt $CurrentCard.Power_DefaultLimit) {
                           $CurrentCard.power_limit = $CurrentCard.Power_DefaultLimit
                           $CurrentCard.PowerChange = "Def" 
                         } else {
                           if ($CurrentCard.temperature_gpu -gt $MaxTemp -And $CurrentCard.power_limit -gt $CurrentCard.Power_MinLimit) {
                             if ($CurrentCard.temperature_gpu - $MaxTemp -gt 1) {
                               [int]$deltapow = [math]::min([math]::floor(($CurrentCard.Power_MaxLimit - $CurrentCard.Power_MinLimit) * 0.2), $CurrentCard.power_limit - $CurrentCard.Power_MinLimit)
                               if ($deltapow -eq 0) {$deltapow = 1}
                             } else {
                               [int]$deltapow = 1
                             }
                             $CurrentCard.power_limit = $CurrentCard.power_limit - $deltapow
                             $CurrentCard.PowerChange = "-{0}" -f $deltapow
                           }
                         }
                         if ($CurrentCard.temperature_gpu -lt $MaxTemp -And $CurrentCard.power_limit -lt $CurrentCard.Power_MaxLimit) {
                           if ($CurrentCard.temperature_gpu -lt $SlowBoost) {
                             if ($CurrentCard.power_limit -lt $CurrentCard.Power_DefaultLimit) {
                               [int]$deltapow = $CurrentCard.Power_DefaultLimit - $CurrentCard.power_limit
                             } else {
                               [int]$deltapow = [math]::min([math]::floor(($CurrentCard.Power_MaxLimit - $CurrentCard.Power_MinLimit) * 0.1), $CurrentCard.Power_MaxLimit - $CurrentCard.power_limit)
                             }
                             if ($deltapow -eq 0) {$deltapow = 1}
                           } else {
                             [int]$deltapow = 1
                           }
                           $CurrentCard.power_limit = $CurrentCard.power_limit + $deltapow
                           $CurrentCard.PowerChange = "+{0}" -f $deltapow
                         }
                         if ($SlowBoost - $CurrentCard.temperature_gpu -gt $MaxTemp - $SlowBoost -And $CurrentCard.power_limit -lt $CurrentCard.Power_MaxLimit) {
                           $CurrentCard.power_limit = $CurrentCard.Power_MaxLimit
                           $CurrentCard.PowerChange = "Max"
                         } else {
                           if ($CurrentCard.temperature_gpu -lt $SlowBoost -And $CurrentCard.power_limit -lt $CurrentCard.Power_DefaultLimit) {
                             $CurrentCard.power_limit = $CurrentCard.Power_DefaultLimit
                             $CurrentCard.PowerChange = "Def"
                           }
                         }
                       } else {
                           if ($CurrentCard.power_minlimit -ne $CurrentCard.power_limit) {
                             $CurrentCard.power_limit = $CurrentCard.power_minlimit
                             $CurrentCard.PowerChange = "Min"
                           }
                       }
                       if ($CurrentCard.PowerChange -ne "No") {
                         [string]$par = "-i {0} -pl {1}" -f $CurrentCard.id, ($CurrentCard.power_limit)
                         "PowerChange {0} {1}" -f $CurrentCard.PowerChange, $CurrentCard.id | out-host
                         invoke-expression "$($cmd) $($par)"
                       }
                     }
  
                   $GpuId+=1
            }   
    
            $NvidiaCards | Format-Table -Wrap  (
                @{Label = "Id"; Expression = {$_.id}},
                @{Label = "Name"; Expression = {$_.gpu_name}},
                @{Label = "Gpu%"; Expression = {$_.utilization_gpu}},   
                @{Label = "Mem%"; Expression = {$_.utilization_memory}}, 
                @{Label = "Temp"; Expression = {$_.temperature_gpu}}, 
                @{Label = "FanSpeed"; Expression = {$_.FanSpeed}},
                @{Label = "Power"; Expression = {$_.power_draw+" /"+$_.power_limit}},
                @{Label = "PLim"; Expression = {$_.Power_LimitPercent}},
                @{Label = "PAdj"; Expression = {$_.PowerChange}},
                @{Label = "pstate"; Expression = {$_.pstate}},
                @{Label = "ClockGpu"; Expression = {$_.ClockGpu}},
                @{Label = "ClockMem"; Expression = {$_.ClockMem}},
                @{Label = "Idle Since"; Expression = {$_.LowLoadStamp}}
            ) | Out-Host

}

$RunLoop = $true

while ($RunLoop) {

  $file = get-content .\nvidiacheck.cfg
  $file | foreach {
    $items = $_.split("=")
    if ($items[0] -eq "maxtemp"){$MaxTemp = $items[1]}
    if ($items[0] -eq "SlowBoost"){$SlowBoost = $items[1]}
    if ($items[0] -eq "LoadTreshold"){$LoadTreshold = $items[1]}
  }

   Clear-host
  "Target {0}C" -f $MaxTemp | out-host

                get-gpu-information
                
                $KeyPressed=Timed_ReadKb 5 ('X')
           
                switch ($KeyPressed){
                    'X' {
                         $RunLoop=$false
                         $KeyPressed=$false
                        }
                    }

}
