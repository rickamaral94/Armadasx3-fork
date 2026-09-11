# UPSTREAM-SYNC

Histórico de sincronização com `ARMSX2/ARMSX3`, conflitos e patches removidos.

## Ponto de partida

| | |
|---|---|
| Importado de | `https://github.com/ARMSX2/ARMSX3` |
| Commit base | `6925a398e528e8081a298403f0d7a4ec78a5c932` |
| Tag | `0.9.7.3` |
| Data | 2026-09-07 |
| Commits no histórico | 20.636 |
| Tags importadas | 29 |

Histórico completo, sem squash, para permitir rebase e cherry-pick.

## Conflitos conhecidos, permanentes

Estes arquivos divergem do upstream por decisão registrada e vão conflitar em
todo `sync/*` que os toque. A resolução é sempre **manter a versão do fork**:

| Arquivo | Motivo | ADR |
|---|---|---|
| `.gitmodules`, `.gitignore` | librashader e libadrenotools pinados | 0001 |
| `android/armsx3-ui/app/build.gradle.kts` | `applicationId` do fork | 0002 |
| `android/armsx3-app/app/build.gradle.kts` | idem | 0002 |
| `.../res/values/strings.xml` | rótulo do launcher | 0002 |
| `android/build-play-aab.sh` | check do applicationId + host portável | 0002 |
| `.../update/UpdaterEntry.kt` | feed de releases do fork | 0002 |
| `.../ui/about/AboutScreen.kt`, `NavigationDrawer.kt`, `i18n/I18n.kt` | links e cadeia de atribuição | 0002 |
| `README.md` | identidade e instruções do fork | 0002 |

## Candidatos a upstream (`upstreamable:`)

Correções genéricas que não são específicas do fork. Quando o upstream as
aceitar, o patch sai daqui.

| Commit | O que corrige | Enviado? |
|---|---|---|
| `2ac5a5c9` | `driver_env.txt` lia o pacote hardcoded; o flavor `play` do upstream já lê o diretório do `github` | não |
| `f1fd9834` | scripts de build eram macOS-only (`darwin-x86_64` fixo); impedem qualquer CI Linux | não |
| parte de `9c064c08` | `ARMSX3_ARM_MARCH` era invisível fora de `rpcs3/`, então não podia ser reportado | não |

## Cadência

Semanal: `sync/<data>` ← `upstream/master` → gate completo (correção +
performance na matriz) → `main`. Um sync não entra em `main` sem passar o gate,
mesmo que só traga commits do upstream.

## Log de syncs

Nenhum ainda — o fork está no commit base.
