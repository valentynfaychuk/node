use proc_macro::TokenStream;
use quote::quote;
use syn::{parse_macro_input, ItemImpl, ItemFn, ImplItem, FnArg, ReturnType, Type, ItemStruct, Fields};

#[proc_macro_attribute]
pub fn contract_state(_attr: TokenStream, item: TokenStream) -> TokenStream {
    let input = parse_macro_input!(item as ItemStruct);
    let name = &input.ident;
    let vis = &input.vis;
    let attrs = &input.attrs;

    let Fields::Named(ref fields) = input.fields else {
        return TokenStream::from(quote! { #input });
    };

    let is_flat = |f: &syn::Field| -> bool {
        f.attrs.iter().any(|attr| attr.path().is_ident("flat"))
    };

    let is_map = |f: &syn::Field| -> bool {
        if let Type::Path(type_path) = &f.ty {
            if let Some(segment) = type_path.path.segments.first() {
                return segment.ident == "Map";
            }
        }
        false
    };

    let is_map_nested = |f: &syn::Field| -> bool {
        if let Type::Path(type_path) = &f.ty {
            if let Some(segment) = type_path.path.segments.first() {
                return segment.ident == "MapNested";
            }
        }
        false
    };

    let transformed_fields = fields.named.iter().map(|f| {
        let field_name = &f.ident;
        let field_vis = &f.vis;
        let field_ty = &f.ty;
        let filtered_attrs: Vec<_> = f.attrs.iter()
            .filter(|attr| !attr.path().is_ident("flat"))
            .collect();

        if is_flat(f) {
            quote! {
                #(#filtered_attrs)*
                #field_vis #field_name: LazyCell<#field_ty>
            }
        } else {
            quote! {
                #(#filtered_attrs)*
                #field_vis #field_name: #field_ty
            }
        }
    });

    let init_calls = fields.named.iter().map(|f| {
        let field = f.ident.as_ref().unwrap();
        let key = field.to_string();

        if is_flat(f) {
            quote! {
                let mut key = prefix.clone();
                key.extend_from_slice(#key.as_bytes());
                self.#field = LazyCell::new(key);
            }
        } else if is_map(f) || is_map_nested(f) {
            quote! {
                let mut key = prefix.clone();
                key.extend_from_slice(#key.as_bytes());
                self.#field.__init_lazy_fields(key);
            }
        } else {
            quote! {
                let mut key = prefix.clone();
                key.extend_from_slice(#key.as_bytes());
                key.push(b':');
                self.#field.__init_lazy_fields(key);
            }
        }
    });

    let flush_calls = fields.named.iter().map(|f| {
        let field = f.ident.as_ref().unwrap();

        if is_flat(f) {
            quote! { self.#field.flush(); }
        } else {
            quote! { self.#field.__flush_lazy_fields(); }
        }
    });

    let default_fields = fields.named.iter().map(|f| {
        let field_name = &f.ident;
        quote! { #field_name: Default::default() }
    });

    TokenStream::from(quote! {
        #(#attrs)*
        #vis struct #name {
            #(#transformed_fields),*
        }

        impl Default for #name {
            fn default() -> Self {
                Self { #(#default_fields),* }
            }
        }

        impl ContractState for #name {
            fn __init_lazy_fields(&mut self, prefix: alloc::vec::Vec<u8>) {
                #(#init_calls)*
            }

            fn __flush_lazy_fields(&self) {
                #(#flush_calls)*
            }
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
                state.__init_lazy_fields(alloc::vec::Vec::new());
                let result = state.#call;
                state.__flush_lazy_fields();
                ret(result);
            }
        } else {
            quote! {
                #(#deserializations)*
                let mut state = #self_ty::default();
                state.__init_lazy_fields(alloc::vec::Vec::new());
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
