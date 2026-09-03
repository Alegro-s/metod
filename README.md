# integrate

Генератор интеграций Space Payments: YAML провайдера → Ruby-сервис, `INTEGRATION.md`, `fixtures.json`.

Без нейросетей. Один движок для CLI и UI. Описание правил: [docs/prototype.md](docs/prototype.md).

## Запуск

Нужен Ruby 3.2+ (стандартные библиотеки, гемов нет).

```bash
# тесты
ruby -Ilib:test test/run.rb

# генерация (эталон кейса)
./integrate --spec examples/novapay.yaml --provider novapay --lang ruby

# второй провайдер (Bearer, другие пути)
./integrate --spec examples/payflow.yaml --provider payflow --lang ruby

# плоский YAML, не OpenAPI
./integrate --spec examples/wallet.yaml --provider wallet --lang ruby

# только IR
./integrate parse --spec examples/novapay.yaml --provider novapay

# веб-мастер на том же движке
./integrate ui --port 4567
```

UI: http://127.0.0.1:4567 — загрузить пример, увидеть роли и warnings, сгенерировать три файла.
