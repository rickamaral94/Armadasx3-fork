# COMPAT-MATRIX

Jogos, estágio alcançado, driver, perfil e regressões.

> **Estado: vazio.** Nenhum jogo foi testado.

## Critério de seleção

**Somente títulos "Playable" no RPCS3 desktop.** Um jogo que já é quebrado no
RPCS3 faz perseguir bug do RPCS3, não do fork — e envenena a matriz com ruído
que nenhuma mudança de ARM64 pode consertar.

12–20 títulos, cobrindo:

- **Referência:** Skate 3 (é o número que o upstream cita).
- **Crash corrigido recentemente:** Borderlands 2, Bleach: Soul Resurrección.
- **Pesado em SPU** / **pesado em PPU-multithread** (separados: apontam para
  recompiladores diferentes).
- **Unreal Engine 3** (classe inteira de jogos se comporta junto).
- **JRPG popular**, **jogo a 60 fps**, **título leve** como sanity check.

## Estágios

`boot` → `menu` → `in-game` → `playable`

## Formato

| Jogo | ID | Estágio (upstream) | Estágio (fork) | Driver recomendado | Perfil | Regressão |
|---|---|---|---|---|---|---|

**Gate:** nenhum jogo da matriz pode ficar abaixo do estágio que tinha no
upstream. Uma regressão de estágio bloqueia a fase, independentemente do ganho
de FPS.
