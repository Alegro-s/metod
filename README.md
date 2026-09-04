# SpaceGen

Генератор коннекта к платёжному провайдеру из OpenAPI.

```bash
bundle install
bundle exec ruby bin/spacegen generate --spec examples/novapay_api.yaml --provider novapay --output ./output
bundle exec rspec

# api + ui
bundle exec ruby bin/spacegen-server
cd web && npm i && npm run dev
```

Ruby 3.4+.
"# Tpay" 
