import os as _os
_WU=_os.environ.get('WINUTIL','../src/winutil').rstrip('/')+'/'
import json,base64,sys
sys.path.insert(0,'.')
from es import ES
src=json.loads(open(_WU+'config/tweaks.json').read(),strict=False)
RP = r'''
$clave = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$anterior = (Get-ItemProperty -Path $clave -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
try {
    Enable-ComputerRestore -Drive "$Env:SystemDrive\" -ErrorAction Stop
    # Windows solo permite un punto cada 24 h; se quita el limite solo durante este paso
    Set-ItemProperty -Path $clave -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord
    Checkpoint-Computer -Description 'OptimizadorES - antes de aplicar ajustes' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    Write-Output 'Punto de restauracion creado correctamente.'
} finally {
    if ($null -eq $anterior) {
        Remove-ItemProperty -Path $clave -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue
    } else {
        Set-ItemProperty -Path $clave -Name SystemRestorePointCreationFrequency -Value $anterior -Type DWord
    }
}
'''
items=[]
order=['WPFTweaksRestorePoint']+[k for k in src if k!='WPFTweaksRestorePoint']
for k in order:
    if k not in ES: continue
    v=src[k]; n,d,r,a=ES[k]
    toggle = v.get('Type')=='Toggle'
    if toggle: g='Preferencias'
    elif r=='Alto' or v['category'].startswith('z__'): g='Avanzados'
    else: g='Esenciales'
    it={'Key':k,'Nombre':n,'Descripcion':d,'Riesgo':r,'Aviso':a,'Grupo':g,'Tipo':'Toggle' if toggle else 'Tweak'}
    for f in ('registry','service','InvokeScript','UndoScript'):
        if v.get(f): it[f]=v[f]
    if k=='WPFTweaksRestorePoint':
        it['InvokeScript']=[RP]
    items.append(it)
items.append({'Key':'OPTUltimatePerformance','Nombre':'Plan de energía Máximo rendimiento','Descripcion':'Añade y activa el plan oculto \'Máximo rendimiento\' (Ultimate Performance).','Riesgo':'Medio','Aviso':'NO recomendado en portátiles: más consumo, calor y menos batería. Deshacer restaura los planes de energía predeterminados (se pierden planes personalizados).','Grupo':'Avanzados','Tipo':'Tweak',
 'InvokeScript':["$out = powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61\n$guid = ($out | Select-String -Pattern '[A-Fa-f0-9-]{36}').Matches.Value\nif (-not $guid) { throw 'powercfg no devolvió el GUID del plan.' }\npowercfg /setactive $guid\n"],
 'UndoScript':["powercfg /restoredefaultschemes\n"]})
js=json.dumps(items,ensure_ascii=False)
b64=base64.b64encode(js.encode('utf-8')).decode()
tpl=open('template.ps1',encoding='utf-8').read()
from apps import APPS
wu=json.loads(open(_WU+'config/applications.json').read(),strict=False)
lista=[]
for cat,k,n,d,a in APPS:
    wid = k[3:] if k.startswith('id:') else wu[k]['winget']
    fuente='winget'
    if wid.startswith('msstore:'): wid=wid[8:]; fuente='msstore'
    ip=_WU+'config/icons/'+k+'.png'
    icono=base64.b64encode(open(ip,'rb').read()).decode() if (not k.startswith('id:') and __import__('os').path.exists(ip)) else ''
    lista.append({'Icono':icono,'Categoria':cat,'Id':wid,'Fuente':fuente,'Nombre':n,'Descripcion':d,'Aviso':a})
apps_b64=base64.b64encode(json.dumps(lista,ensure_ascii=False).encode()).decode()
from extras import EXTRAS
ext_b64=base64.b64encode(json.dumps(EXTRAS,ensure_ascii=False).encode()).decode()
tpl=tpl.replace('__EXTRAS_B64__',ext_b64)
out=tpl.replace('__DATOS_B64__',b64).replace('__APPS_B64__',apps_b64).replace('__ICONO_PNG__',base64.b64encode(open('icono64.png','rb').read()).decode()).replace('__ICONO_ICO__',base64.b64encode(open('icono.ico','rb').read()).decode())
open(_os.environ.get('SALIDA','/mnt/project-files/optimizador-es/OptimizadorES.ps1'),'w',encoding='utf-8-sig',newline='\r\n').write(out)
from collections import Counter
print(len(items), Counter((i['Grupo'],i['Riesgo']) for i in items))
