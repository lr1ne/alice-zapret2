# windows-auto-install.ps1 - установка zapret2 на Яндекс Станцию с ПК под Windows.
#
# Что делает скрипт:
#   1) проверяет наличие adb (при отсутствии просит указать путь);
#   2) спрашивает IP-адрес колонки и подключается к ней по ADB (порт 5555);
#   3) копирует install.sh, start.sh, stop.sh, uninstall.sh, hosts.txt и
#      S99zapret2 в /data/tmp/zapret2-install/ на колонке;
#   4) запускает install.sh, который ставит zapret2 в /data/opt/zapret2;
#   5) предлагает удалить временные файлы с колонки.
#
# Запуск (PowerShell от имени администратора):
#   Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
#   .\windows-auto-install.ps1
#
# Требуется adb (Android platform-tools) в PATH либо путь к нему будет
# запрошен. На колонке должна быть включена отладка по ADB.

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

# Show-Log "сообщение" -Type INFO|SUCCESS|WARN|ERROR|ACTION|INPUT|OK [-NoNewline]
# Единообразный цветной вывод сообщений.
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

Show-Log "Скрипт подключится к вашей колонке по ADB и установит всё необходимое." -Type INFO
Show-Log "ПРОВЕРЕНО ТОЛЬКО НА ЯНДЕКС СТАНЦИЯ МИНИ 2." -Type WARN

# ---- Подтверждение запуска --------------------------------------------------
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

# Папка files лежит рядом со скриптом; оттуда берутся все компоненты.
$LocalPath = "$PSScriptRoot\files" 
# Временный каталог на колонке, куда копируются файлы перед установкой.
$RemotePath = "/data/tmp/zapret2-install/"
# Список файлов для передачи. uninstall.sh тоже нужен установщику: он
# копирует его в /data/opt/zapret2 рядом с start.sh.
$FilesToCopy = @(
    "$LocalPath\install.sh",
    "$LocalPath\start.sh",
    "$LocalPath\stop.sh",
    "$LocalPath\uninstall.sh",
    "$LocalPath\hosts.txt",
    "$LocalPath\S99zapret2"
)

# ---- Основная логика --------------------------------------------------------
function Installation {
    $AdbPath = "adb"

    # adb может отсутствовать в PATH — тогда просим указать путь к бинарнику.
    Show-Log "Проверяю наличие ADB в системе..." -Type ACTION
    if (-not (Get-Command adb.exe -ErrorAction SilentlyContinue)) {
        Show-Log "ADB не найден в системном PATH." -Type WARN
        
        while ($true) {
            Show-Log "Укажите полный путь к исполняемому файлу adb: " -Type INPUT -NoNewline
            $InputPath = (Read-Host).Trim()

            # Пользователь может ввести путь в кавычках — убираем их.
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

    # Проверяем, что все компоненты на месте, до подключения к колонке.
    foreach ($File in $FilesToCopy) {
        if (-not (Test-Path $File)) {
            Show-Log "Файлы не найдены на ПК: $(Split-Path $File -Leaf)" -Type ERROR
            Show-Log "Убедитесь, что папка 'files' находится рядом со скриптом и содержит все компоненты." -Type WARN
            return
        }
    }
    
    $AliceIp = $null

    # Запрашиваем IP, пока не получим корректный IPv4-адрес.
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

    # Подключение по ADB. Сам connect может вернуть ошибку, поэтому реальную
    # проверку делаем по списку устройств ниже.
    Show-Log "Подключаюсь к станции по ADB ($AliceIp)..." -Type INFO
    & $AdbPath connect "${AliceIp}:5555" | Out-Null

    Start-Sleep -Seconds 1

    # Ищем в `adb devices` строку вида "<IP>:5555<TAB>device".
    # Точки в IP экранируем, иначе они совпадут с любым символом.
    $EscapedIp = [regex]::Escape($AliceIp)
    $DevicesOutput = & $AdbPath devices
    $IsConnected = $false

    foreach ($Line in $DevicesOutput) {
        if ($Line -match "^$EscapedIp\b.*?\bdevice\b") {
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

    # Готовим временный каталог на колонке.
    Show-Log "Создаю временную папку на Станции..." -Type INFO
    & $AdbPath shell "mkdir -p $RemotePath"
    if ($LASTEXITCODE -ne 0) {
        Show-Log "Не удалось создать $RemotePath на колонке." -Type ERROR
        return
    }

    # Копируем файлы по одному и проверяем результат каждой передачи.
    Show-Log "Переношу файлы через ADB..." -Type ACTION
    foreach ($File in $FilesToCopy) {
        $FileName = Split-Path $File -Leaf
        Show-Log "  $FileName" -Type INFO
        & $AdbPath push $File "$RemotePath/$FileName"
        if ($LASTEXITCODE -ne 0) {
            Show-Log "Ошибка при передаче файла $FileName через ADB." -Type ERROR
            return
        }
    }
    Show-Log "Все файлы успешно перенесены через ADB!" -Type SUCCESS

    # install.sh сам ставит zapret2, конфиги и автозапуск.
    Show-Log "Запускаю установочный скрипт на Станции..." -Type ACTION
    Show-Log "Выдаю права на выполнение и запускаю install.sh..." -Type INFO
    
    & $AdbPath shell "chmod +x ${RemotePath}install.sh && ${RemotePath}install.sh"
    $InstallExitCode = $LASTEXITCODE

    # По желанию убираем временные файлы, чтобы не занимать место в /data.
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
