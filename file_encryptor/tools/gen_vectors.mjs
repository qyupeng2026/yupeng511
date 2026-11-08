import { webcrypto as crypto } from 'node:crypto';

const MAGIC = Uint8Array.from([0x46,0x45,0x4E,0x43]);
const VERSION_GCM=1, VERSION_CTR=2;
const SALT_LEN=16, IV_BASE_LEN=8, CTR_IV_LEN=16;
const GCM_HEADER_LEN=4+1+SALT_LEN+IV_BASE_LEN+4;
const CTR_HEADER_LEN=4+1+SALT_LEN+CTR_IV_LEN;
const CHUNK_SIZE=1024*1024, TAG_LEN=16, HMAC_LEN=32, PBKDF2_ITERATIONS=250000;

const enc = new TextEncoder();
const password = 'Test@123456';
const plaintext = 'FENC compatibility test payload — 中文内容 — 0123456789';
const data = enc.encode(plaintext);

function concat(...arrs){let n=arrs.reduce((s,a)=>s+a.length,0);let o=new Uint8Array(n),p=0;for(const a of arrs){o.set(a,p);p+=a.length}return o}

async function deriveKeyGCM(password, salt) {
  const base = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveKey']);
  return crypto.subtle.deriveKey({name:'PBKDF2',salt,iterations:PBKDF2_ITERATIONS,hash:'SHA-256'},base,{name:'AES-GCM',length:256},false,['encrypt']);
}
function makeGCMIV(base,counter){const iv=new Uint8Array(12);iv.set(base,0);new DataView(iv.buffer).setUint32(8,counter,false);return iv;}
function buildGCMHeader(salt,ivBase,chunkSize){const b=new Uint8Array(GCM_HEADER_LEN);const v=new DataView(b.buffer);b.set(MAGIC,0);b[4]=VERSION_GCM;b.set(salt,5);b.set(ivBase,5+SALT_LEN);v.setUint32(5+SALT_LEN+IV_BASE_LEN,chunkSize,false);return b;}
function buildCTRHeader(salt,iv){const b=new Uint8Array(CTR_HEADER_LEN);b.set(MAGIC,0);b[4]=VERSION_CTR;b.set(salt,5);b.set(iv,5+SALT_LEN);return b;}

async function encryptGCM(data,password){
  const salt=crypto.getRandomValues(new Uint8Array(SALT_LEN));
  const ivBase=crypto.getRandomValues(new Uint8Array(IV_BASE_LEN));
  const header=buildGCMHeader(salt,ivBase,CHUNK_SIZE);
  const key=await deriveKeyGCM(password,salt);
  const total=Math.max(1,Math.ceil(data.length/CHUNK_SIZE));
  const parts=[header];
  for(let i=0;i<total;i++){
    const start=i*CHUNK_SIZE,end=Math.min(start+CHUNK_SIZE,data.length);
    const plain=data.slice(start,end);
    const iv=makeGCMIV(ivBase,i);
    const aad=new Uint8Array([i===total-1?1:0]);
    const c=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:aad,tagLength:128},key,plain);
    parts.push(new Uint8Array(c));
  }
  return concat(...parts);
}

async function encryptCTR(data,password){
  const salt=crypto.getRandomValues(new Uint8Array(SALT_LEN));
  const iv=crypto.getRandomValues(new Uint8Array(CTR_IV_LEN));
  const fileKey=crypto.getRandomValues(new Uint8Array(32));
  const hmacKey=crypto.getRandomValues(new Uint8Array(32));
  const wrapKey=await deriveKeyGCM(password,salt);
  const bundle=new Uint8Array(64);bundle.set(fileKey,0);bundle.set(hmacKey,32);
  const wrapIV=crypto.getRandomValues(new Uint8Array(12));
  const wrapped=new Uint8Array(await crypto.subtle.encrypt({name:'AES-GCM',iv:wrapIV,tagLength:128},wrapKey,bundle));
  const extra=new Uint8Array(12+wrapped.length);extra.set(wrapIV,0);extra.set(wrapped,12);
  const base=buildCTRHeader(salt,iv);
  const header=concat(base,extra);
  const total=Math.max(1,Math.ceil(data.length/CHUNK_SIZE));
  const parts=[header];const chunks=[];
  const aesKey=await crypto.subtle.importKey('raw',fileKey,'AES-CTR',false,['encrypt']);
  for(let i=0;i<total;i++){
    const start=i*CHUNK_SIZE,end=Math.min(start+CHUNK_SIZE,data.length);
    const plain=data.slice(start,end);
    const blockIV=new Uint8Array(CTR_IV_LEN);blockIV.set(iv.slice(0,8),0);new DataView(blockIV.buffer).setBigUint64(8,BigInt(i),false);
    const c=new Uint8Array(await crypto.subtle.encrypt({name:'AES-CTR',counter:blockIV,length:64},aesKey,plain));
    chunks.push(c);parts.push(c);
  }
  const hmacData=concat(iv,...chunks);
  const hk=await crypto.subtle.importKey('raw',hmacKey,{name:'HMAC',hash:'SHA-256'},false,['sign']);
  const tag=new Uint8Array(await crypto.subtle.sign('HMAC',hk,hmacData));
  parts.push(tag);
  return concat(...parts);
}

const toHex=b=>Buffer.from(b).toString('hex');
const gcm=await encryptGCM(data,password);
const ctr=await encryptCTR(data,password);
console.log(JSON.stringify({password,plaintext,gcmLen:gcm.length,ctrLen:ctr.length,gcmHex:toHex(gcm),ctrHex:toHex(ctr)}));
