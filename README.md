# uxdeployar — instalador

Instala uxdeployar en un VPS recién creado desde tu PC; no hace falta abrir una sesión en el VPS.

- Linux o macOS: `curl -fsSL https://raw.githubusercontent.com/uxlelmar-eaac/uxdeployar-install/main/instalar | bash`
- Windows (PowerShell): `irm https://raw.githubusercontent.com/uxlelmar-eaac/uxdeployar-install/main/instalar.ps1 | iex`

Este repositorio lo actualiza el workflow de release de uxdeployar.

## Después de instalar

En el panel, abre la **Guía** → capítulo **Recorrido completo del operador** (orden recomendado: servidor → apps → HTTPS → copias → restore de plataforma → actualizar). La restauración de la plataforma usa la llave de recuperación que guardaste al configurar Respaldos.
