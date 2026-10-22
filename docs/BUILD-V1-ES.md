# Windows 11 Optimized Builder V1 — guía rápida

**Estado:** paquete de construcción inicial. No incluye Windows ni una ISO de Microsoft. Obtén la ISO directamente de Microsoft.

## Uso
1. Extrae todo el ZIP a una carpeta local, por ejemplo `C:\\Win11Builder` (no ejecutes desde dentro del ZIP).
2. Descarga una ISO oficial de Windows 11: https://www.microsoft.com/software-download/windows11
3. Haz doble clic en `LAUNCH_TINY11.bat` y acepta el aviso UAC para elevar privilegios.
4. Sigue la interfaz para seleccionar la ISO o unidad montada, edición y opciones.
5. Conserva `tiny11_*.log` y `tiny11_*.dism.log` para diagnosticar errores.
6. Prueba la ISO resultante en una máquina virtual antes de instalarla en hardware físico.

## Requisitos
- Windows PowerShell 5.1.
- Privilegios de administrador.
- DISM de Windows 11 24H2/25H2, versión 10.0.26100 o posterior.
- Windows ADK Deployment Tools si el host no dispone de un DISM compatible.
- 20 GB libres como mínimo; 40 GB o más recomendados.
- ISO original de Windows 11 24H2 o 25H2.

## Balanced V1
El constructor parte de Tiny11 Maker Reforged y aplica una lista acotada de eliminaciones de aplicaciones de consumo/promoción. Conserva componentes críticos para actualización, seguridad, reparación y desarrollo. El bypass de requisitos de hardware y el bloqueo de OneDrive no se activan por defecto: solo se usan si el usuario los solicita expresamente.

## Seguridad y limitaciones
- No instales una imagen personalizada en tu equipo principal sin validarla en una VM.
- No se garantiza “cero telemetría”.
- En hardware no compatible, Microsoft no garantiza soporte ni actualizaciones futuras.
- No compartas una ISO de Windows generada; cada usuario debe usar medios oficiales.
- Este entorno no ejecuta Windows/DISM, por lo que no ha construido ni arrancado una ISO.

## Archivos principales
- `tiny11maker.ps1`: motor de construcción.
- `lib/`: módulos GUI y utilidades.
- `autounattend.xml`: configuración de instalación desatendida.
- `tests/`: pruebas estáticas y de comportamiento con mocks.
- `docs/`: especificación Balanced V1, decisiones y plan de actualización de imágenes.
