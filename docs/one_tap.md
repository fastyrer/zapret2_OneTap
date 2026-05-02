# One Tap запуск

Проект теперь разделён на платформенные one-click сценарии.

## Linux/OpenWrt

`one_tap.sh` - неинтерактивный запускатель для Linux/OpenWrt.

Запуск:

```sh
sudo ./one_tap.sh
```

Что он делает:

- копирует проект в `/opt/zapret2`, если он запущен из другой папки;
- определяет init-систему и firewall backend;
- ставит runtime-зависимости через системный пакетный менеджер;
- подключает готовые бинарники или собирает их из исходников, если готовых нет;
- при первой настройке запускает `blockcheck2.sh` в batch-режиме;
- сохраняет подобранную стратегию в `config`;
- включает и запускает сервис.

Повторные запуски используют сохранённый `config`.

Полезные override-переменные:

```sh
ONE_TAP_FORCE_SCAN=1 sudo ./one_tap.sh
ONE_TAP_DOMAINS="rutracker.org example.org" sudo ./one_tap.sh
ONE_TAP_SCANLEVEL=force sudo ./one_tap.sh
ONE_TAP_AUTOSCAN=0 sudo ./one_tap.sh
```

## Windows

Запуск из готового release bundle с Windows-бинарниками:

```cmd
one_tap_windows.bat
```

Что делает Windows-сценарий:

- проверяет права администратора и наличие `winws2.exe`, `cygwin1.dll`, `WinDivert.dll`, `WinDivert*.sys`;
- если Windows-бинарников нет, пытается скачать их из GitHub Releases в `binaries\windows-x86_64` или `binaries\windows-x86`;
- создаёт набор стратегий и проверяет их на обычном HTTPS-сайте, реальных страницах/ассетах YouTube, Telegram и Discord;
- создаёт hostlist целей в `windows\state\one-tap-target-hosts.txt`, чтобы стратегии не трогали весь интернет;
- создаёт отдельный hostlist для Discord в `windows\state\discord-hosts.txt` и пробует Discord-ориентированные TLS/QUIC/media стратегии;
- пока проверка не проходит, перезапускает `winws2` со следующей стратегией;
- сохраняет первую рабочую стратегию в `windows\strategy.windows.args`;
- создаёт итоговый `windows\winws2.args`;
- сохраняет пути в `windows\config.windows.ps1`;
- ставит или обновляет сервис `winws2` и запускает его.

Повторный запуск использует сохранённую стратегию. Чтобы сбросить её к дефолтной:

```cmd
one_tap_windows.bat -ResetStrategy
```

Останов:

```cmd
windows\stop_windows.cmd
```

Самопроверка структуры без установки сервиса:

```cmd
one_tap_windows.bat -SelfTest
```

Запуск без автоматической проверки YouTube/Telegram/Discord:

```cmd
one_tap_windows.bat -NoProbe
```

Если окно закрылось слишком быстро, откройте `cmd.exe` в папке проекта и запустите ту же команду вручную. Логи пишутся в `windows\state\one_tap_windows_launcher.log` и `windows\state\one_tap_windows.log`.
Отчёт проверки соединения пишется в `windows\state\connectivity-test.json`.
Внутри каждой группы проверяются все URL, чтобы, например, Discord API не давал ложный успех при неработающем gateway/CDN.
Часть проверок дополнительно читает тело ответа и требует минимальный размер/ожидаемый текст, чтобы служебный HTTP-код не давал ложный успех при неработающей загрузке страницы.
Для отдельных reachability URL HTTP-ответы вроде `403 Forbidden` или `404 Not Found` считаются успешной сетевой достижимостью: сервер ответил, значит DNS/TLS/маршрут прошли.
Если Discord не проходит, в предупреждении будет указан конкретный провалившийся URL.
Широкие стратегии, которые применяются ко всему HTTPS-трафику, по умолчанию пропускаются. Если они нужны для ручного эксперимента, задайте `ZAPRET2_ALLOW_BROAD_STRATEGIES=1`.

В source checkout Windows-бинарников обычно нет. Обычный запуск пытается скачать их автоматически. По умолчанию проверяются релизы `fastyrer/zapret2_OneTap`, затем `bol-van/zapret2`. Если нужен другой источник, задайте переменную:

```cmd
set ZAPRET2_RELEASE_REPO=owner/repo
one_tap_windows.bat
```

Автозагрузку можно отключить:

```cmd
one_tap_windows.bat -NoDownload
```

Если интернета нет, положите `winws2.exe`, `cygwin1.dll`, `WinDivert.dll`, `WinDivert64.sys` в `binaries\windows-x86_64` вручную или соберите Windows artifacts по `docs\compile`.

## macOS

```sh
macos/one_tap_macos.sh --self-test
```

macOS-сценарий проверяет и при необходимости собирает только поддерживаемые user-space утилиты `ip2net` и `mdig`, затем сохраняет состояние в `macos/state/config.macos`.

Прозрачный запуск основного DPI-перехвата на macOS не включён намеренно. В текущей архитектуре `zapret2` нужен kernel divert механизм: на Linux это NFQUEUE, на BSD - `ipfw`/`pf`, на Windows - WinDivert. В современных macOS подходящего `ipdivert`/`PF divert-packet` пути нет, поэтому честная macOS-версия требует отдельной архитектуры, например Network Extension или прокси-режим.
