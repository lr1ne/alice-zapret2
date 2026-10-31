$Logo = @'

▐▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▌
▐  █████╗ ██╗     ██╗ ██████╗███████╗                       ▌
▐ ██╔══██╗██║     ██║██╔════╝██╔════╝                       ▌
▐ ███████║██║     ██║██║     █████╗                         ▌
▐ ██╔══██║██║     ██║██║     ██╔══╝                         ▌
▐ ██║  ██║███████╗██║╚██████╗███████╗                       ▌
▐ ╚═╝  ╚═╝╚══════╝╚═╝ ╚═════╝╚══════╝                       ▌
▐                                                           ▌
▐ ███████╗ █████╗ ██████╗ ██████╗ ███████╗████████╗██████╗  ▌
▐ ╚══███╔╝██╔══██╗██╔══██╗██╔══██╗██╔════╝╚══██╔══╝╚════██╗ ▌
▐   ███╔╝ ███████║██████╔╝██████╔╝█████╗     ██║    █████╔╝ ▌
▐  ███╔╝  ██╔══██║██╔═══╝ ██╔══██╗██╔══╝     ██║   ██╔═══╝  ▌
▐ ███████╗██║  ██║██║     ██║  ██║███████╗   ██║   ███████╗ ▌
▐ ╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚══════╝ ▌
▐▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▌

'@

function Show-Log {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR', 'ACTION', 'INPUT', 'OK')]
        [string]$Type = 'INFO',
        
        [switch]$NoNewline
    )

    switch ($Type) {
        'INFO'    { Write-Host " [i] [INFO]    " -ForegroundColor Cyan -NoNewline }
        'SUCCESS' { Write-Host " [+] [SUCCESS] " -ForegroundColor Green -NoNewline }
        'WARN'    { Write-Host " [!] [WARN]    " -ForegroundColor Yellow -NoNewline }
        'ERROR'   { Write-Host " [-] [ERROR]   " -ForegroundColor Red -NoNewline }
        'ACTION'  { Write-Host " [>] [ACTION]  " -ForegroundColor Magenta -NoNewline }
        'INPUT'   { Write-Host " [?] [INPUT]   " -ForegroundColor Magenta -NoNewline }
        'OK'      { Write-Host " [✓] [OK]      " -ForegroundColor Green -NoNewline }
    }

    if ($NoNewline) {
        Write-Host $Message -NoNewline
    } else {
        if ($Type -eq 'ERROR') {
            Write-Host $Message -ForegroundColor Red
        } elseif ($Type -eq 'SUCCESS' -or $Type -eq 'OK') {
            Write-Host $Message -ForegroundColor Green
        } elseif ($Type -eq 'WARN') {
            Write-Host $Message -ForegroundColor Yellow
        } else {
            Write-Host $Message -ForegroundColor White
        }
    }
}

Write-Host $Logo -ForegroundColor Green

Show-Log "Скрипт подключится к вашей колонке по ssh и установит всё необходимое." -Type INFO
Show-Log "ПРОВЕРЕНО ТОЛЬКО НА ЯНДЕКС СТАНЦИЯ МИНИ 2." -Type WARN

$Choices = [System.Management.Automation.Host.ChoiceDescription[]] @(
    New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Продолжить установку (по умолчанию)"
    New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Выйти из скрипта"
)

$Decision = $Host.UI.PromptForChoice(
    "Автоматическая установка zapret2 на Яндекс Станцию", 
    "Вы хотите продолжить выполнение скрипта?", 
    $Choices, 
    0
)
$LocalPath = "$PSScriptRoot\files" 
$RemotePath = "/data/tmp/zapret2-install/"
$FilesToCopy = @(
    "$LocalPath\install.sh",
    "$LocalPath\start.sh",
    "$LocalPath\stop.sh",
    "$LocalPath\hosts.txt",
    "$LocalPath\S99zapret2"
)

function Installation {
    $AdbPath = "adb"

    Show-Log "Проверяю наличие ADB в системе..." -Type ACTION
    if (-not (Get-Command adb.exe -ErrorAction SilentlyContinue)) {
        Show-Log "ADB не найден в системном PATH." -Type WARN
        
        while ($true) {
            Show-Log "Укажите полный путь к исполняемому файлу adb: " -Type INPUT -NoNewline
            $InputPath = (Read-Host).Trim()

            $CleanPath = $InputPath -replace '^"|"$' , ''

            if (Test-Path $CleanPath -PathType Leaf) {
                $AdbPath = $CleanPath
                break
            } elseif (Test-Path (Join-Path $CleanPath "adb.exe") -PathType Leaf) {
                $AdbPath = Join-Path $CleanPath "adb.exe"
                break
            } else {
                Show-Log "Файл adb.exe не найден по указанному пути. Попробуйте еще раз." -Type ERROR
            }
        }
    }

    foreach ($File in $FilesToCopy) {
        if (-not (Test-Path $File)) {
            Show-Log "Файлы не найдены на ПК: $(Split-Path $File -Leaf)" -Type ERROR
            Show-Log "Убедитесь, что папка 'files' находится рядом со скриптом и содержит все компоненты." -Type WARN
            return
        }
    }
    
    $AliceIp = $null

    while ($true) {
        Show-Log "Введите IP-адрес вашей Яндекс Станции: " -Type INPUT -NoNewline
        $InputIp = (Read-Host).Trim()

        if ([string]::IsNullOrWhiteSpace($InputIp)) {
            Show-Log "IP-адрес не может быть пустым!" -Type ERROR
            continue
        }

        $IpRegex = '^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
        
        if ($InputIp -match $IpRegex) {
            $AliceIp = $InputIp
            break
        } else {
            Show-Log "Неверный формат IP! Пример правильного: 192.168.1.50" -Type ERROR
        }
    }

    Show-Log "IP-адрес принят: $AliceIp" -Type OK
    Show-Log "Подготовка к переносу файлов..." -Type ACTION

    Show-Log "Подключаюсь к станции по ADB ($AliceIp)..." -Type INFO
    & $AdbPath connect "${AliceIp}:5555" | Out-Null

    Start-Sleep -Seconds 1

    $DevicesOutput = & $AdbPath devices
    $IsConnected = $false

    foreach ($Line in $DevicesOutput) {
        if ($Line -match "$AliceIp\b.*?\bdevice\b") {
            $IsConnected = $true
            break
        }
    }

    if (-not $IsConnected) {
        Show-Log "Не удалось установить ADB-соединение с $AliceIp!" -Type ERROR
        Show-Log "Убедитесь, что:" -Type WARN
        Show-Log "  1. Указан правильный IP-адрес." -Type WARN
        Show-Log "  2. Колонка включена и находится в одной сети с ПК." -Type WARN
        Show-Log "  3. На станции включен режим отладки (ADB)." -Type WARN
        return
    }

    Show-Log "Успешное подключение к Яндекс Станции!" -Type SUCCESS

    Show-Log "Создаю временную папку на Станции..." -Type INFO
    & $AdbPath shell "mkdir -p $RemotePath"

    Show-Log "Переношу файлы через ADB..." -Type ACTION
    foreach ($File in $FilesToCopy) {
        $FileName = Split-Path $File -Leaf
        & $AdbPath push $File "$RemotePath/$FileName"
    }

    if ($LASTEXITCODE -eq 0) {
        Show-Log "Все файлы успешно перенесены через ADB!" -Type SUCCESS
    } else {
        Show-Log "Ошибка при передаче файлов через ADB." -Type ERROR
        return
    }

    Show-Log "Запускаю установочный скрипт на Станции..." -Type ACTION
    Show-Log "Выдаю права на выполнение и запускаю install.sh..." -Type INFO
    
    & $AdbPath shell "chmod +x ${RemotePath}install.sh && ${RemotePath}install.sh"
    $InstallExitCode = $LASTEXITCODE

    $CleanupChoices = [System.Management.Automation.Host.ChoiceDescription[]] @(
        New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Удалить установочные файлы из /data/tmp (рекомендуется)"
        New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Оставить файлы в системе для отладки"
    )

    $CleanupDecision = $Host.UI.PromptForChoice(
        "Очистка временных файлов", 
        "Хотите удалить установочный скрипт с колонки?", 
        $CleanupChoices, 
        0
    )

    if ($CleanupDecision -eq 0) {
        Show-Log "Очищаю временную папку на колонке..." -Type ACTION
        & $AdbPath shell "rm -rf $RemotePath"

        if ($LASTEXITCODE -eq 0) {
            Show-Log "Временные файлы на колонке успешно удалены." -Type SUCCESS
        } else {
            Show-Log "Не удалось удалить временные файлы на колонке." -Type WARN
        }
    } else {
        Show-Log "Очистка отменена. Временные файлы сохранены в $RemotePath" -Type INFO
    }

    if ($InstallExitCode -eq 0) {
        Show-Log "Скрипт на колонке отработал успешно!" -Type SUCCESS
    } else {
        Show-Log "Произошла ошибка при выполнении install.sh на стороне Станции." -Type ERROR
    }
}


if ($Decision -eq 0) {
    Show-Log "Запуск процесса установки..." -Type ACTION
    Installation
} else {
    Show-Log "Установка отменена пользователем. Выход..." -Type ERROR
    Exit
}
