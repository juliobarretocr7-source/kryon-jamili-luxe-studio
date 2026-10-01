# KRYON + JAMILI LUXE STUDIO

Fundação real (Etapa 7B, auditada). Veja [`docs/FUNDACAO-7B.md`](docs/FUNDACAO-7B.md): o que foi construído, a seção **"Auditoria e correções finais"**, o que foi realmente testado e o que ainda depende de PostgreSQL real.

```bash
npm run test:local   # revisão estática + simulação lógica (Node) — roda em qualquer máquina
npm run db:test      # testes SQL — exigem PostgreSQL/Supabase real (ainda NÃO executados)
```

O protótipo `luxe-studio.html` (Etapas 1-6) continua sendo a referência visual e de regras de negócio (não foi alterado) até a Etapa 7H substituí-lo pelo fluxo público real.
