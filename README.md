# allinone

Скрипт для настройки Remnawave-ноды: firewall, ICMP, nginx, SSL, Docker, remnanode, fail2ban, roscom.dat.
Собран из [remnawave-guide](https://github.com/herbalsomml/remnawave-guide) и части скриптов этого репозитория.

данные скрипты собраны из ИИ
не советую к использованию.

## Запуск с сервера одной командой

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/juhnsooqa/allinone/main/remnawave-node-setup.sh)"
```

Откроется интерактивное меню. Либо сразу конкретный шаг:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/juhnsooqa/allinone/main/remnawave-node-setup.sh)" -- full
```

Доступные аргументы: `full`, `fail2ban`, `roscom`, `psiphon`, `accelerator`, `reverse-proxy`.

После первого запуска на сервере появляется команда `allinone` — открывает то же меню (каждый раз с последней версией скрипта с GitHub):

```bash
allinone            # меню
allinone psiphon    # сразу меню Psiphon
```

## Настройка хостов в панели

По мотивам [remnawave-guide](https://github.com/herbalsomml/remnawave-guide#настройки-tcp-хоста) (там же скриншоты).
Скрипт печатает эти же настройки с вашим доменом и сохраняет их в `/opt/remnanode/panel-hosts.txt`.
Профиль с инбаундами — `/opt/remnanode/panel-profile.reference.json`.

В панели: **Хосты → Создать**, для каждого хоста выбрать свой инбаунд и ноду, `<ДОМЕН>` — домен ноды.

**Основные**

| Хост | Инбаунд | Адрес | Порт |
|---|---|---|---|
| TCP | `NODE_TCP` | `<ДОМЕН>` | `44443` |
| XHTTP | `NODE_XHTTP` | `<ДОМЕН>` | `443` |
| gRPC | `NODE_GRPC` | `<ДОМЕН>` | `44444` |

**Расширенные**

| Поле | TCP и gRPC | XHTTP |
|---|---|---|
| SNI | `<ДОМЕН>` | `<ДОМЕН>` |
| Переопределить SNI из адреса | вкл | **выкл** |
| Хост | — | `<ДОМЕН>` |
| Путь | — | `/xhttppath/` (со слешем на конце, как на ноде) |
| Security Layer | по умолчанию | TLS |
| ALPN | — | `h2,http/1.1` |
| Отпечаток | — | `chrome` |

Для XHTTP ещё: **Xray Json & Raw → xHTTP** — вставить `/opt/remnanode/panel-xhttp-host-extra.reference.json`.

## Psiphon

Пункт меню 6 ставит Psiphon как SOCKS-выход для xray ([psiphon/psiphon_install.sh](psiphon/psiphon_install.sh), копия [Chara-Freedom/vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon), MIT).
Ставить только на зарубежную ноду. После установки в `/opt/remnanode/panel-profile.reference.json` добавляется аутбаунд `psiphon-out` и правило для `geosite:openai`/`geosite:google-gemini` (только TCP).
Управление — через меню или напрямую `vps-psiphon {status|rotate|region CC|speed|logs|uninstall}`.
