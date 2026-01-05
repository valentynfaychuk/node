use proc_macro::TokenStream;
use quote::quote;
use syn::{parse_macro_input, DeriveInput, Data, Fields, ItemImpl, ItemFn, ImplItem, FnArg, ReturnType, Type};

#[proc_macro_derive(Contract)]
pub fn derive_contract(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    let name = &input.ident;
    let Data::Struct(data) = &input.data else { return TokenStream::new() };
    let Fields::Named(fields) = &data.fields else { return TokenStream::new() };

    let init_calls = fields.named.iter().map(|f| {
        let field = f.ident.as_ref().unwrap();
        let key = field.to_string();
        quote! { self.#field = LazyCell::new(b!("__state__::", #key)); }
    });

    let flush_calls = fields.named.iter().map(|f| {
        let field = f.ident.as_ref().unwrap();
        quote! { self.#field.flush(); }
    });

    TokenStream::from(quote! {
        impl #name {
            pub fn __init_lazy_fields(&mut self) { #(#init_calls)* }
            pub fn __flush_lazy_fields(&self) { #(#flush_calls)* }
        }
    })
}

#[proc_macro_attribute]
pub fn contract(_attr: TokenStream, item: TokenStream) -> TokenStream {
    if let Ok(impl_block) = syn::parse::<ItemImpl>(item.clone()) {
        return handle_impl_block(impl_block);
    }
    if let Ok(function) = syn::parse::<ItemFn>(item.clone()) {
        return handle_function(function);
    }
    item
}

fn handle_impl_block(impl_block: ItemImpl) -> TokenStream {
    let self_ty = &impl_block.self_ty;
    let mut methods = Vec::new();
    let mut wrappers = Vec::new();

    for item in impl_block.items.iter() {
        let ImplItem::Fn(method) = item else { continue };
        if !matches!(method.vis, syn::Visibility::Public(_)) { continue };

        let name = &method.sig.ident;
        let has_return = !matches!(method.sig.output, ReturnType::Default);
        let has_self = method.sig.inputs.iter().any(|arg| matches!(arg, FnArg::Receiver(_)));

        if !has_self {
            methods.push(method);
            continue;
        }

        let args: Vec<_> = method.sig.inputs.iter()
            .filter_map(|arg| match arg {
                FnArg::Typed(pat_type) => {
                    let param = &pat_type.pat;
                    let ptr = syn::Ident::new(&format!("{}_ptr", quote!(#param)), name.span());
                    let deser = match &*pat_type.ty {
                        Type::Path(tp) if quote!(#tp).to_string().contains("String") => quote!(read_string),
                        _ => quote!(read_bytes),
                    };
                    Some((quote!(#ptr: i32), quote!(let #param = #deser(#ptr);), quote!(#param)))
                }
                _ => None,
            })
            .collect();

        let params: Vec<_> = args.iter().map(|(p, _, _)| p).collect();
        let deserializations: Vec<_> = args.iter().map(|(_, d, _)| d).collect();
        let call_args: Vec<_> = args.iter().map(|(_, _, c)| c).collect();

        let sig = if params.is_empty() {
            quote!(#[no_mangle] pub extern "C" fn #name())
        } else {
            quote!(#[no_mangle] pub extern "C" fn #name(#(#params),*))
        };

        let call = if call_args.is_empty() {
            quote!(#name())
        } else {
            quote!(#name(#(#call_args),*))
        };

        let body = if has_return {
            quote! {
                #(#deserializations)*
                let mut state = #self_ty::default();
                state.__init_lazy_fields();
                let result = state.#call;
                state.__flush_lazy_fields();
                ret(result);
            }
        } else {
            quote! {
                #(#deserializations)*
                let mut state = #self_ty::default();
                state.__init_lazy_fields();
                state.#call;
                state.__flush_lazy_fields();
            }
        };

        wrappers.push(quote! { #sig { #body } });
        methods.push(method);
    }

    TokenStream::from(quote! {
        impl #self_ty { #(#methods)* }
        #(#wrappers)*
    })
}

fn handle_function(input: ItemFn) -> TokenStream {
    let vis = &input.vis;
    let name = &input.sig.ident;
    let impl_name = syn::Ident::new(&format!("{}_impl", name), name.span());
    let inputs = &input.sig.inputs;
    let output = &input.sig.output;
    let block = &input.block;
    let attrs = &input.attrs;
    let has_return = !matches!(output, ReturnType::Default);

    let mut idx = 0;
    let mut params = quote!{};
    let mut deserializations = quote!{};
    let mut call_args = quote!{};

    for arg in inputs.iter() {
        if let FnArg::Typed(pat_type) = arg {
            let param = &pat_type.pat;
            let ptr = syn::Ident::new(&format!("arg{}_ptr", idx), name.span());
            let deser = match &*pat_type.ty {
                Type::Path(tp) if quote!(#tp).to_string().contains("String") => quote!(read_string),
                _ => quote!(read_bytes),
            };

            if idx > 0 {
                params.extend(quote!(, #ptr: i32));
                call_args.extend(quote!(, #param));
            } else {
                params.extend(quote!(#ptr: i32));
                call_args.extend(quote!(#param));
            }

            deserializations.extend(quote! { let #param = #deser(#ptr); });
            idx += 1;
        }
    }

    let sig = if idx == 0 {
        quote!(#[no_mangle] pub extern "C" fn #name())
    } else {
        quote!(#[no_mangle] pub extern "C" fn #name(#params))
    };

    let call = if has_return {
        quote!(ret(#impl_name(#call_args));)
    } else {
        quote!(#impl_name(#call_args);)
    };

    TokenStream::from(quote! {
        #sig { #deserializations #call }
        #(#attrs)* #vis fn #impl_name(#inputs) #output #block
    })
}
