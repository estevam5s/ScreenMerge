# ScreenMerge

App nativo para macOS que **junta dois monitores 1920×1080 em um único display virtual de 3840×1080**.

Alternativa gratuita ao BetterDisplay Pro para merge de monitores.

## Como funciona

1. Cria um **display virtual de 3840×1080** usando o BetterDisplay (gratuito)
2. **Captura** o conteúdo do display virtual a 60fps via ScreenCaptureKit
3. **Renderiza** metade esquerda no monitor esquerdo e metade direita no monitor direito
4. **Move as janelas** automaticamente dos monitores físicos para o display virtual
5. **Prende o cursor** no display virtual para interação (toggle com atalho)

O resultado: macOS enxerga **um único monitor de 3840×1080**. Fullscreen, Dock, Spaces — tudo funciona como se fosse uma tela só.

## Requisitos

- **macOS 14+** (Sonoma ou superior)
- **BetterDisplay** (gratuito) — [Download](https://github.com/waydabber/BetterDisplay)
- **Dois monitores externos 1920×1080**
- Permissões: **Gravação de Tela** e **Acessibilidade**

## Instalação

### Build do código fonte

```bash
git clone https://github.com/estevam5s/ScreenMerge.git
cd ScreenMerge
swift build -c release
```

### Criar o .app bundle

```bash
mkdir -p /Applications/ScreenMerge.app/Contents/MacOS
cp .build/release/ScreenMerge /Applications/ScreenMerge.app/Contents/MacOS/

cat > /Applications/ScreenMerge.app/Contents/Info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ScreenMerge</string>
    <key>CFBundleIdentifier</key>
    <string>com.estevam.screenmerge</string>
    <key>CFBundleName</key>
    <string>ScreenMerge</string>
    <key>CFBundleVersion</key>
    <string>3.0</string>
    <key>CFBundleShortVersionString</key>
    <string>3.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>ScreenMerge precisa capturar o display virtual para renderizar nos monitores fisicos.</string>
</dict>
</plist>
EOF

codesign -f -s - --deep /Applications/ScreenMerge.app
xattr -cr /Applications/ScreenMerge.app
```

### Permissões (primeira vez)

1. Abra o app
2. macOS vai pedir permissão de **Gravação de Tela** — conceda
3. Vá em **Ajustes > Privacidade e Segurança > Acessibilidade** — ative o ScreenMerge
4. Reinicie o app

## Uso

### Menu bar
Clique no ícone (⊞) na barra de menus para abrir o painel de controle.

### Ativar/Desativar
- Clique em **"Ativar Merge"** no painel
- Ou lance com auto-ativação: `open /Applications/ScreenMerge.app --args --activate`

### Controle do cursor
- **Ctrl+Shift+Esc** — alterna entre cursor preso (no display virtual) e livre (acessa o MacBook)
- Ou clique **"Liberar Cursor"** / **"Prender Cursor"** no painel

### O que acontece ao ativar
1. Janelas dos monitores físicos são movidas para o display virtual
2. Overlays cobrem os monitores físicos mostrando o conteúdo do display virtual
3. Cursor é preso no display virtual

### O que acontece ao desativar
1. Janelas voltam para os monitores físicos
2. Overlays são removidos
3. Display virtual é destruído

## Arquitetura

```
┌─────────────────────────────────────────────┐
│          Display Virtual 3840×1080          │
│         (criado via BetterDisplay)          │
│                                             │
│  ┌─────────────────┬─────────────────┐     │
│  │  Metade Esquerda │  Metade Direita │     │
│  │    1920×1080     │    1920×1080    │     │
│  └────────┬────────┴────────┬────────┘     │
│           │ ScreenCaptureKit │              │
│           │   (60fps, BGRA)  │              │
└───────────┼──────────────────┼──────────────┘
            │                  │
    ┌───────▼────────┐ ┌──────▼─────────┐
    │ Monitor Esq.   │ │ Monitor Dir.   │
    │ 1920×1080      │ │ 1920×1080      │
    │ (Overlay Left) │ │ (Overlay Right)│
    │ contentsRect   │ │ contentsRect   │
    │ [0,0,0.5,1]    │ │ [0.5,0,0.5,1] │
    └────────────────┘ └────────────────┘
```

**Tecnologias:**
- **BetterDisplay CLI** — criação/gestão do display virtual
- **ScreenCaptureKit** — captura do framebuffer a 60fps
- **IOSurface** — compartilhamento zero-copy GPU
- **CALayer** — renderização com contentsRect para crop eficiente
- **CGEventTap** — cursor jail no display virtual

## Limitações

- Requer BetterDisplay instalado (gratuito, mas necessário)
- A qualidade depende da captura de tela (pode ter leve latência)
- Streaming protegido por HDCP pode não funcionar nos monitores (limitação do DisplayLink)
- Ao reconstruir o app, precisa re-conceder permissão de Gravação de Tela

## Licença

MIT
