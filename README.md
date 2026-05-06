# rw-node-optimize

Оптимизация RemnaWave-ноды: sysctl, Docker, лимиты дескрипторов, CAKE shaping.

## Установка одной командой

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh) --yes
```

## Dry-run (без изменений)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh) --dry-run
```

## Опции

| Флаг | Описание |
|------|----------|
| `--yes` | Применить изменения |
| `--dry-run` | Только диагностика, без мутаций |
| `--speed <mbit>` | CAKE shaping (пример: `50`, `500kbit`, `1gbit`) |
| `--debug` | Расширенный DEBUG-раздел в конце вывода |

## Проверка целостности перед запуском

```bash
mkdir -p scripts
curl -fsSLo VERSION https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/VERSION
curl -fsSLo manifest.sha256 https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/manifest.sha256
curl -fsSLo scripts/optimize-bootstrap.sh https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh
curl -fsSLo scripts/optimize.sh https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize.sh
curl -fsSLo scripts/diag.sh https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/diag.sh
curl -fsSLo scripts/snapshot.sh https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/snapshot.sh
sha256sum -c manifest.sha256
```
