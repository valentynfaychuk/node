import { globalState } from './state.js'

export function getFileNameWithoutExtension(filename) {
    const lastDotIndex = filename.lastIndexOf('.');
    if (lastDotIndex === -1) return filename; // Return the original name if there's no dot.
    return filename.slice(0, lastDotIndex);
}

const MAP = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
export function to_b58(term) {return (typeof term === 'string' || term instanceof String) ? to_b58_1(new TextEncoder().encode(term)) : to_b58_1(term)}
// eslint-disable-next-line
function to_b58_1(B,A) {if(!A){A=MAP};var d=[],s="",i,j,c,n;for(i in B){j=0,c=B[i];s+=c||s.length^i?"":1;while(j in d||c){n=d[j];n=n?n*256+c:c;c=n/58|0;d[j]=n%58;j++}}while(j--)s+=A[d[j]];return s};
export function from_b58(term) {return from_b58_1(term)}
// eslint-disable-next-line
function from_b58_1(S,A) {if(!A){A=MAP};var d=[],b=[],i,j,c,n;for(i in S){j=0,c=A.indexOf(S[i]);if(c<0)return undefined;c||b.length^i?i:b.push(0);while(j in d||c){n=d[j];n=n?n*58+c:c;c=n>>8;d[j]=n%256;j++}}while(j--)b.push(d[j]);return new Uint8Array(b)};
