// before first paint: the stored choice (System/Light/Dark), else the system's
try{var t=localStorage.getItem("tando-theme");if(t==="dark"||t!=="light"&&matchMedia("(prefers-color-scheme: dark)").matches)document.documentElement.classList.add("dark")}catch(e){}
