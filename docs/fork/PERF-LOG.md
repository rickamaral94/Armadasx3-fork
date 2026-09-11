# PERF-LOG

Uma entrada por mudança que pretende afetar performance. Ordem cronológica.

> **Estado: vazio.** Nenhuma mudança de performance foi feita. A Fase 0
> (bootstrap) não toca em caminho quente por definição; otimizar antes de ter
> `BASELINE.md` seria exatamente o que a regra 1 proíbe.

## Formato obrigatório

```
## <data> — <prefixo>: <título>

**Hipótese:** <afirmação falsificável>
**Evidência que motivou:** <o que no perfil apontou para cá>
**Critério de falsificação:** se <X> não cair <Y>% em <onde>, a hipótese está errada
**Patch:** <commits>
**Build:** <build record json>

| jogo | driver | cache | antes (mediana) | depois (mediana) | Δ | dispersão |
|---|---|---|---|---|---|---|

**Gate de correção:** <resultado da suíte PPU/SPU / comparação de imagem>
**Veredito:** <adotado L0/L1/L2/L3 | rejeitado | sem efeito>
```

## Regras que esta tabela impõe

- **Ganho menor que o ruído = "sem efeito".** Não "leve melhora". Se a
  dispersão entre 5 runs cobre o Δ, o veredito é sem efeito e a mudança é
  revertida ou fica como perfil por jogo.
- **Antes e depois medidos na mesma sessão térmica**, com os dois APKs
  instalados (é para isso que o fork tem `applicationId` próprio).
- **Cache frio e quente nunca se misturam** na mesma linha.
- Uma entrada sem gate de correção preenchido não conta como adotada.

## Escada de generalização

Um ganho só sobe de nível com evidência **daquele** nível:

| Nível | Evidência | Resultado |
|---|---|---|
| L0 | 1 jogo, 1 cena, 1 driver | vira **perfil por jogo**, nunca default |
| L1 | matriz inteira no A740, 1 driver | default no A740 |
| L2 | matriz no A740, proprietário **e** Turnip | default no A740, ambos drivers |
| L3 | acima disso | default global do fork |
