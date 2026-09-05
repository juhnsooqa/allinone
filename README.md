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

Доступные аргументы: `full`, `fail2ban`, `roscom`, `accelerator`, `reverse-proxy`.
