import os as _os
_WU=_os.environ.get('WINUTIL','../src/winutil').rstrip('/')+'/'
import json
W=_WU+''
feat=json.loads(open(W+'config/feature.json').read(),strict=False)
FE = {
 "WPFFeaturesdotnet": (".NET Framework 3.5 (versiones 2, 3 y 4)", "Necesario para programas antiguos de contabilidad, facturación o juegos viejos.", "Bajo", "Descarga componentes de Windows Update; puede tardar."),
 "WPFFeatureslegacymedia": ("Componentes multimedia heredados", "Windows Media Player clásico y DirectPlay, para juegos y programas antiguos.", "Bajo", ""),
 "WPFFeaturenfs": ("Cliente NFS", "Acceder a carpetas compartidas de servidores Linux o NAS por NFS.", "Bajo", ""),
 "WPFFeaturewsl": ("Subsistema de Windows para Linux (WSL)", "Ejecutar Linux dentro de Windows.", "Medio", "Activa la plataforma de virtualización: algunos antitrampas de juegos y VirtualBox/VMware antiguos pueden fallar o ir más lentos."),
 "WPFFeatureshyperv": ("Hyper-V", "Máquinas virtuales de Microsoft. Solo Windows Pro, Enterprise o Education.", "Medio", "Puede impedir que funcionen VirtualBox/VMware antiguos y algunos antitrampas, y bajar un poco el rendimiento en juegos."),
 "WPFFeaturesSandbox": ("Windows Sandbox", "Escritorio desechable para probar programas sospechosos sin riesgo. Solo Pro/Enterprise.", "Medio", "Activa la virtualización (mismos efectos que Hyper-V en juegos con antitrampas)."),
 "WPFFeatureRegBackup": ("Copia diaria del registro", "Programa una copia automática del registro cada día a las 00:30.", "Bajo", "Ocupa unos pocos MB en disco."),
 "WPFFeatureEnableLegacyRecovery": ("Activar menú F8 al arrancar", "Recupera el menú clásico de recuperación pulsando F8 al encender.", "Bajo", "El arranque puede tardar unos segundos más."),
 "WPFFeatureDisableLegacyRecovery": ("Quitar menú F8 al arrancar", "Vuelve al arranque normal de Windows (deshace la opción anterior).", "Bajo", ""),
}
def q(x): return "'" + x.replace("'","''") + "'"
features=[]
for k,(n,d,r,a) in FE.items():
    v=feat[k]; fl=v.get('feature') or []
    clave='FEAT:'+k
    code=f"Set-EstadoApp -Id {q(clave)} -Texto 'Activando...' -Tipo 'trabajo'\n$fallo = $false\n"
    if fl:
        code+="foreach ($f in @(" + ",".join(q(x) for x in fl) + ")) {\n    try { Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart -ErrorAction Stop | Out-Null; Write-Output \"Activada: $f\" }\n    catch { $fallo = $true; Write-Warning \"No se pudo activar ${f}: $($_.Exception.Message)\" }\n}\n"
    scripts=v.get('InvokeScript') or []
    if scripts:
        code+="if (-not $fallo) {\n" + "\n".join(scripts) + "\n}\n"
    code+=f"if ($fallo) {{ Set-EstadoApp -Id {q(clave)} -Texto 'No se pudo activar (ver registro)' -Tipo 'error'; throw 'Alguna característica no se pudo activar (puede que tu edición de Windows no la tenga).' }}\nSet-EstadoApp -Id {q(clave)} -Texto 'Activada $([char]0x2714) (reinicia el equipo)' -Tipo 'ok'\n"
    features.append({'Key':k,'Nombre':n,'Descripcion':d,'Riesgo':r,'Aviso':a,'Features':fl,'Script':code})
dns=json.loads(open(W+'config/dns.json').read(),strict=False)
DN={"Google":"Google (8.8.8.8)","Cloudflare":"Cloudflare (1.1.1.1) - rápido","Cloudflare_Malware":"Cloudflare con bloqueo de malware","Cloudflare_Malware_Adult":"Cloudflare familiar (malware + adultos)","Open_DNS":"OpenDNS","Quad9":"Quad9 (bloquea malware)","AdGuard_Ads_Trackers":"AdGuard (bloquea anuncios)","AdGuard_Ads_Trackers_Malware_Adult":"AdGuard familiar"}
dnsl=[{'Nombre':DN[k],'P':v['Primary'],'S':v['Secondary'],'P6':v['Primary6'],'S6':v['Secondary6']} for k,v in dns.items()]
pre=json.loads(open(W+'config/preset.json').read(),strict=False)
def fn(path,call):
    return open(W+'functions/public/'+path,encoding='utf-8').read()+"\n"+call+"\n"
EXTRAS={'Features':features,'Dns':dnsl,'Presets':{'Standard':pre['Standard'],'Minimal':pre['Minimal']},
 'Updates':{'default':fn('Invoke-WPFUpdatesdefault.ps1','Invoke-WPFUpdatesdefault'),
            'security':fn('Invoke-WPFUpdatessecurity.ps1','Invoke-WPFUpdatessecurity'),
            'disable':fn('Invoke-WPFUpdatesdisable.ps1','Invoke-WPFUpdatesdisable -Confirmed')}}
