use vecpak::{Term, encode_term};

pub trait EncodeToTerm {
    fn to_term(&self) -> Result<Term, &'static str>;
}
pub trait EncodeIntoBuf {
    fn encode_into_buf(&self, buf: &mut Vec<u8>) -> Result<(), &'static str>;
}
impl<T: EncodeToTerm> EncodeIntoBuf for T {
    fn encode_into_buf(&self, buf: &mut Vec<u8>) -> Result<(), &'static str> {
        let term = self.to_term()?;
        encode_term(buf, term); // use &term if your encoder takes &Term
        Ok(())
    }
}

pub trait DecodeFromTerm: Sized {
    fn from_term(t: &Term) -> Self;
}

#[inline]
pub fn pl_find<'a>(pairs: &'a [(Term, Term)], key: &[u8]) -> &'a Term {
    &pairs
        .iter()
        .find(|(k, _)| matches!(k, Term::Binary(b) if b.as_slice() == key))
        .unwrap()
        .1
}

#[inline]
pub fn pl_get_varint(pairs: &[(Term, Term)], key: &[u8]) -> i128 {
    match pl_find(pairs, key) {
        Term::VarInt(x) => *x,
        _ => unreachable!(),
    }
}

#[inline]
pub fn pl_get_u64(pairs: &[(Term, Term)], key: &[u8]) -> u64 {
    pl_get_varint(pairs, key) as u64
}

#[inline]
pub fn pl_get_bytes<'a>(pairs: &'a [(Term, Term)], key: &[u8]) -> &'a [u8] {
    match pl_find(pairs, key) {
        Term::Binary(v) => v.as_slice(),
        _ => unreachable!(),
    }
}
#[inline]
pub fn pl_get_list<'a>(pairs: &'a [(Term, Term)], key: &[u8]) -> &'a [Term] {
    match pl_find(pairs, key) {
        Term::List(v) => v.as_slice(),
        _ => unreachable!(),
    }
}
