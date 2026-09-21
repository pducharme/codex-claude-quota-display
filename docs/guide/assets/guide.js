"use strict";
const menu = document.getElementById("menu-toggle");
menu.onclick = () => {const expanded=menu.getAttribute("aria-expanded") !== "true";menu.setAttribute("aria-expanded",expanded);document.getElementById("navigation").classList.toggle("open",expanded);};
let index;
const search=document.getElementById("search"), results=document.getElementById("search-results");
const normalize=s=>s.toLocaleLowerCase("fr").normalize("NFD").replace(/[\u0300-\u036f]/g,"");
search.oninput=async()=>{
 const query=normalize(search.value.trim());results.replaceChildren();results.hidden=!query;if(!query)return;
 try{
  if(!index){const response=await fetch("search.json");if(!response.ok)throw Error();index=await response.json();}
  if(normalize(search.value.trim())!==query)return;
  const matches=index.filter(p=>query.split(/\s+/).every(word=>normalize(p.title+" "+p.text).includes(word)));
  const count=document.createElement("p");count.textContent=matches.length+" rubrique(s) trouvée(s)";results.append(count);
  for(const page of matches){const a=document.createElement("a");a.href=page.url;a.textContent=page.title;const p=document.createElement("p");const at=Math.max(0,normalize(page.text).indexOf(query)-50);p.textContent=page.text.slice(at,at+180)+"…";results.append(a,p);}
 }catch(e){results.textContent="Recherche indisponible. Les rubriques restent accessibles dans le menu.";}
};
