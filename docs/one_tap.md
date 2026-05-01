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
windows\one_tap_windows.cmd
```

Что делает Windows-сценарий:

- проверяет права администратора и наличие `winws2.exe`, `cygwin1.dll`, `WinDivert.dll`, `WinDivert*.sys`;
- создаёт `windows\strategy.windows.args`, если стратегии ещё нет;
- создаёт итоговый `windows\winws2.args`;
- сохраняет пути в `windows\config.windows.ps1`;
- ставит или обновляет сервис `winws2` и запускает его.

Повторный запуск использует сохранённую стратегию. Чтобы сбросить её к дефолтной:

```cmd
windows\one_tap_windows.cmd -ResetStrategy
```

Останов:

```cmd
windows\stop_windows.cmd
```

Самопроверка структуры без установки сервиса:

```cmd
windows\one_tap_windows.cmd -SelfTest
```

В source checkout Windows-бинарников обычно нет. Их нужно брать из release bundle или собирать по `docs\compile`.

## macOS

```sh
macos/one_tap_macos.sh --self-test
```

macOS-сценарий проверяет и при необходимости собирает только поддерживаемые user-space утилиты `ip2net` и `mdig`, затем сохраняет состояние в `macos/state/config.macos`.

Прозрачный запуск основного DPI-перехвата на macOS не включён намеренно. В текущей архитектуре `zapret2` нужен kernel divert механизм: на Linux это NFQUEUE, на BSD - `ipfw`/`pf`, на Windows - WinDivert. В современных macOS подходящего `ipdivert`/`PF divert-packet` пути нет, поэтому честная macOS-версия требует отдельной архитектуры, например Network Extension или прокси-режим.
