// Página de reservas por negocio: pone el icono y el nombre del negocio en el HTML
// (iPhone/Android leen el icono al cargar, sin esperar al JavaScript).
const SB='https://jiokzzzdepinumbrjalm.supabase.co',KEY='sb_publishable_ITxafkZCiuhtCUTvxPSZJA_CerS0vtY';
const OK=/^assets\/[a-z0-9_-]+\/[A-Za-z0-9._-]+-\d+\.png$/i;
async function biz(slug){
  try{const r=await fetch(SB+'/rest/v1/rpc/public_business',{method:'POST',headers:{apikey:KEY,Authorization:'Bearer '+KEY,'Content-Type':'application/json'},body:JSON.stringify({p_slug:slug})});
    const b=await r.json();if(!b||!b.ok)return null;return b}catch(e){return null}}
export async function onRequest({request,env,params}){
  const url=new URL(request.url),slug=String(params.slug||'').toLowerCase();
  const b=/^[a-z0-9-]{1,60}$/.test(slug)?await biz(slug):null;
  const ic=b&&b.business&&b.business.icon,base=ic&&OK.test(ic)?ic.replace(/-\d+\.png$/,''):null;
  if(url.searchParams.has('m')){
    if(!b||!base)return Response.redirect(url.origin+'/manifest.webmanifest',302);
    const m={name:b.name,short_name:b.name.slice(0,12),start_url:'/r/'+slug,scope:'/',display:'standalone',background_color:'#ffffff',theme_color:'#009955',lang:'es',
      icons:[{src:'/'+base+'-192.png',sizes:'192x192',type:'image/png'},{src:'/'+base+'-512.png',sizes:'512x512',type:'image/png'}]};
    return new Response(JSON.stringify(m),{headers:{'content-type':'application/manifest+json','cache-control':'public,max-age=300'}});
  }
  const page=await env.ASSETS.fetch(new Request(url.origin+'/reservas'));
  if(!b||!base)return page;
  const name=b.name.replace(/[<>"&]/g,'');
  return new HTMLRewriter()
    .on('link[rel="apple-touch-icon"]',{element(e){e.setAttribute('href','/'+base+'-180.png')}})
    .on('link#mf',{element(e){e.setAttribute('href','/r/'+slug+'?m=1')}})
    .on('meta[name="apple-mobile-web-app-title"]',{element(e){e.setAttribute('content',name)}})
    .transform(new Response(page.body,{status:200,headers:{'content-type':'text/html; charset=utf-8','cache-control':'no-cache'}}));
}
