const {spawn,execSync}=require('child_process');const fs=require('fs');const IORedis=require('ioredis');
const path=require('path');const RS=process.env.SPIKE_REDIS_BIN||'redis-server';exports.OUT=process.env.SPIKE_OUT||path.join(__dirname,'out');exports.RS=RS;
exports.sleep=ms=>new Promise(r=>setTimeout(r,ms));
exports.startRedis=async(port,dir,extra=[])=>{fs.rmSync(dir,{recursive:true,force:true});fs.mkdirSync(dir,{recursive:true});
 const p=spawn(RS,['--port',String(port),'--dir',dir,'--daemonize','no','--save','','--appendonly','no',...extra],{stdio:'ignore'});
 for(let i=0;i<100;i++){try{const c=new IORedis(port,{lazyConnect:true,maxRetriesPerRequest:1});await c.connect();await c.ping();c.disconnect();return p;}catch(e){await exports.sleep(100);}}
 throw new Error('redis start fail');};
exports.conn=port=>new IORedis(port,{maxRetriesPerRequest:null});
require('fs').mkdirSync(exports.OUT,{recursive:true});
