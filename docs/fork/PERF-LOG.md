# PERF-LOG

Uma entrada por mudança que pretende afetar performance. Ordem cronológica.

> **Estado: nenhuma mudança de performance feita.** O que existe abaixo é a
> primeira **atribuição** medida — hipótese com evidência, não patch. Otimizar
> antes disso seria exatamente o que a regra 1 proíbe.

---

## 2026-09-16 — atribuição: God of War III está preso em reserva de SPU, não na GPU

**Ainda não é uma entrada de mudança.** É o alvo que a Fase 1 existia para
encontrar, registrado com a evidência antes de qualquer patch.

**Fonte:** `armsx3-amaral-diag-20260916-1503.zip`, build `9a0c23e2`, Turnip Mesa
26.3.0-devel, GoW III (BCUS98111), `RSX Profiler` ligado, 44 relatórios de 300
quadros. **Uma sessão só.**

### O que o perfil mostra

Cena leve (menu), 0:44–0:47, estável: **17,5 ms/quadro**, 0–6 quadros de cada 300
acima de 33 ms, 80% do tempo da thread RSX ocioso, 2 draws/quadro.

Cena pesada, a partir de 0:47:11: **121–140 ms/quadro**, ~8 fps, **100% dos
quadros acima de 33 ms** e 60–90% acima de 100 ms, pior quadro 351 ms.

A repartição do último relatório (121,03 ms/quadro):

| bucket | ms/quadro | % |
|---|---|---|
| **Idle: FIFO empty** | **48,155** | **39,8%** |
| Local task | 17,899 | 14,8% |
| Fence poll | 9,311 | 7,7% |
| FIFO decode | 8,260 | 6,8% |
| Vertex/index | 7,502 | 6,2% |
| Method handlers | 6,354 | 5,2% |
| Idle: guest semaphore | 3,991 | 3,3% |
| Fence wait | 3,288 | 2,7% |

**40% do quadro a thread RSX não tem o que fazer.** O gargalo não é a GPU e não é
o renderizador: é o lado convidado não entregando comandos.

### Para onde o lado convidado foi

```
PUTLLC       175.808–204.016/quadro, 24% FALHAM (≈3,5M de 14,6M)
  destes ~10.000/quadro pegaram vm::writer_lock (≈355/quadro no bloco SPURS,
  accurate_reservations=ON)
PUTLLC/10s:  +15.216.594
SPU          4,4–4,8 de 6 executando / 1,2–1,6 esperando
```

E o próprio jogo diz, 367 vezes pelo `sys_tty`:

    BATCHJOB: AddJob: waiting for room in job list 3 for job 56...

O escalonador de jobs do GoW3 está bloqueado esperando vaga na lista — ou seja, os
SPUs não terminam o trabalho a tempo. ~200 mil `PUTLLC` por quadro com 24% de
falha e retry, e dez mil por quadro passando pelo `vm::writer_lock`, é onde o
tempo de SPU está indo.

### Hipótese a testar (H1)

**`Accurate SPU Reservations` (`spu_accurate_reservations`, ligado por padrão) é
o item que dita o ritmo do GoW3 neste aparelho.** O próprio profiler imprime o
gate ao lado do número, o que torna o A/B trivial.

**Critério de falsificação:** com a opção desligada, mesma cena, mesma sessão
térmica, se a linha `pacing` não melhorar **fora da dispersão entre 5 runs**, H1
está errada e a atribuição volta para a mesa.

**Gate de correção obrigatório antes de qualquer adoção:** esta opção troca
precisão de emulação por velocidade. Sem suíte PPU/SPU limpa e sem comparação de
imagem, um ganho aqui não é adotável nem como perfil por jogo.

### Candidatos secundários, registrados e NÃO perseguidos agora

- **`NV4097_NO_OPERATION`: 123.655/quadro, 48,6% de todos os métodos.** Metade do
  tráfego de FIFO é NOP. Custa parte dos 11,3 ms/quadro de decode+refill — mas a
  thread RSX tem 40% de ociosidade, então **não é o item que dita o ritmo** e
  otimizar aqui não devolveria quadro nenhum hoje.
- **`NV4097_SET_BEGIN_END`: 16,258 ms/quadro**, 5.762 chamadas, 2.821 ns cada,
  para 2.881 draws/quadro. Mesmo argumento.
- **`fence polls 10,8/quadro a 858.711 ns cada, 0,0% "not ready"`.** Um
  `vkGetFenceStatus` que sempre encontra a fence pronta e ainda assim custa 858 µs
  é estranho o suficiente para virar pergunta sobre o Turnip. Não é conclusão: o
  contador pode estar medindo mais do que a chamada.
- **`change_image_layout` derruba 36,1 render passes/quadro** de 70,9 totais.
  Território do Q1, mas **sem pressão de memória neste run** (7,2 GB livres), o
  que exclui a hipótese de vazamento para esta sessão.

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
