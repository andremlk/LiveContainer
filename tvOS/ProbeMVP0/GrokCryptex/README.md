# Grok cryptex pass — `tvos-mvp8-grok-cryptex`

Versión de prueba. No afirma que el DDI quede instalado. Cambia solo lo que
se puede justificar sin tumbar `cryptexd` a ciegas.

## Qué incluye

1. Bucle de ventana para el preámbulo XPC de cada file-transfer. El cliente
   anterior llamaba `_send_flow_controlled` una vez y descartaba el número de
   bytes enviados. Si la ventana del peer era menor que el preámbulo, el
   payload empezaba a mitad de cabecera.
2. Log de tamaños anunciados (`image`, `trustcache`, `im4m`, `info`,
   `volumehash`) antes de `install`.
3. Test local de ventana corta. No usa el Apple TV.
4. Extractor de strings contra un binario tvOS 18.6 si lo tienes del IPSW.
5. Override opcional `LCTV_CRYPTEX_IMAGE_TYPE_INDEX`. El default sigue siendo
   **10**. No se barre el índice en hardware.

## Qué no incluye

- No cambia el índice por 5/8/9 “because iPhone”.
- No desinstala un Cryptex fantasma (`copy_installed` ya estaba vacío).
- No toca MVP8F / Infuse. Sin `debugproxy` en un túnel nuevo no hay JIT.

## Cómo probar (Termux)

Desde el checkout de esta rama:

```bash
# 1. Solo host, sin TV
python3 tvOS/ProbeMVP0/GrokCryptex/lctv_cryptex_window_test.py
# o: bash bin/lctv grok-test

# 2. Si tienes libcryptex_core o cryptexd de tvOS 18.6
python3 tvOS/ProbeMVP0/GrokCryptex/lctv_cryptex_strings.py /ruta/libcryptex_core
```

Copia `GrokCryptex/` junto a `Tools/` en `~/lctv-mvp8-fix/LiveContainerTV-Termux`
y deja el helper actualizado. `lctv jit repair` carga los parches aunque el
directorio no sea visible dentro de proot (van inlined en el helper).

Un intento de hardware, no una barrida:

```bash
# default: image-type-index=10, con preámbulo reparado y logs
bash "$LCTV" jit repair
```

Si repair muere otra vez con `asset already present: Cryptex1,GenericVolume`,
**para**. Conserva el log. No relances con otro índice salvo que el extractor
de strings (o una captura de `devicectl` contra tvOS 18.6) demuestre qué
entrada de `cryptex_asset_types` es `gdmg`.

Override consciente, una sola vez, solo con evidencia:

```bash
export LCTV_CRYPTEX_IMAGE_TYPE_INDEX=5   # ejemplo, no un valor recomendado
bash "$LCTV" jit repair
```

Criterio de PASS (igual que el handoff):

- `LCTV JIT: REPAIR PASS`
- `copy_installed` ve `com.apple.MobileAsset.DDI`
- `debugproxy` aparece en un túnel **nuevo**
- ningún crash de `cryptexd`

Después, y solo después: `bash "$LCTV" jit launch`.
