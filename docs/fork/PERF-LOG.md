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

### H1 — FALSIFICADA em 2026-09-16 15:33

**Fonte:** `armsx3-amaral-diag-20260916-1533.zip`, mesma build, mesmo driver,
`Reservas precisas de SPU` **desligada**, profiler ligado, 72 relatórios. O log
confirma `accurate_reservations=off` em todos.

A intervenção funcionou perfeitamente **no próprio contador**:

| | accurate=ON | accurate=off | Δ |
|---|---|---|---|
| `PUTLLC`/quadro | 168k–204k | **35k–36k** | −82% |
| `PUTLLC` que falham | 23–25% | **0,9–1,0%** | −96% |
| `vm::writer_lock`/quadro | ~10.000 | **0** | −100% |
| SPU executando (de 6) | 4,4–4,8 | 4,5–4,9 | ~igual |
| **`Idle: FIFO empty`** | **39,8%** | **39,4%** | **inalterado** |
| ms/quadro (mediana da cena pesada) | 120,4 | 102,7 | −15% |

**Veredito: H1 está errada.** Removemos 165 mil operações atômicas por quadro e
as dez mil tomadas de lock por quadro — e a fração do quadro em que o
renderizador fica **sem nada para desenhar não se moveu**: 39,8% → 39,4%. Se a
contenção de reserva fosse o item que ditava o ritmo, essa linha teria caído.

Os −15% de mediana **não sustentam nada**, e é importante dizer por quê em vez
de vendê-los: as faixas se sobrepõem (ON 34–140, off 74–144), é uma sessão de
cada, e **as cenas não são as mesmas** — a captura com a opção desligada tem
3.886 draws/quadro contra 2.881, e alvos de 1408×1408 que não aparecem na outra.
Um número desses, com esse confound, é ruído com sinal de mais.

O que dá para afirmar é o mecanismo, e esse independe de cena: o contador
diretamente afetado caiu 82% e o desfecho não acompanhou.

**Consequência:** o lado convidado continua não alimentando o FIFO, e agora
sabemos que não é sincronização de reserva. Sobra **vazão de execução de SPU** —
o código que o recompilador LLVM gera. Que é exatamente onde a Fase 4 deveria
estar olhando, e agora com evidência em vez de suposição.

### Onde o tempo de SPU está (amostras de PC, quadros lentos)

    pc=0x10a80   13,3–15,6%
    pc=0x0d7c0   10,3–12,3%
    pc=0x03700    5,9–6,3%
    pc=0x03500    4,2–4,9%

**Três a quatro blocos concentram ~30% do tempo de SPU.** Endereço de local
store não identifica o programa sozinho — jobs diferentes carregam no mesmo LS —
então isso é um ponteiro para investigar, não um alvo confirmado.

### H2 — candidata: o poll de fence custa 13 ms/quadro no Turnip

`VKGSRenderTypes.hpp` já registra que `vkGetFenceStatus` no Adreno media **19,7
ms por chamada** e devolvia `VK_NOT_READY` zero vezes em 300 quadros — "a wait
wearing a query's name" — e por isso foi trocado por `vkWaitForFences` com
timeout zero.

A troca ajudou e **não resolveu**. Medido agora:

    fence polls  12,8/quadro, 1.047.841 ns cada, 0,0% not ready
    Fence poll   13,371 ms/quadro   12,7%

Um `vkWaitForFences(timeout=0)` numa fence que **sempre** já está sinalizada
custando 1 ms por chamada é 100× o esperado. É específico de driver, é do
mandato deste fork, e **não troca precisão por velocidade** — é pedir menos ao
driver.

**Mas não é o próximo passo, e a razão é a mesma que vale para o NOP:** a thread
RSX já fica ~40% ociosa. Economizar 13 ms nela hoje vira mais ociosidade, não
mais quadros. **H2 só vale depois que o lado convidado deixar de ser o gargalo.**
Fica registrada agora para não ser redescoberta.

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
