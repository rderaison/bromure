//! Bromure differential oracle, destination half (scratch; test-only).
//! Mirrors `hydrate_destination_plan` + `validate_destination` with DNS
//! answers injected instead of resolved.
use super::destination::{AddressAuthorization, build_validation_plan};
use super::{
    NetworkAction, endpoint_config_string_array, validate_allowed_ips_for_resolved_addrs,
    validate_declared_endpoint_resolved_addrs, reject_internal_resolved_addrs,
};
use std::net::{IpAddr, SocketAddr};

pub(crate) fn oracle_destination(
    auth: &crate::opa::EgressAuthorization,
    host: &str,
    port: u16,
    resolved: &[IpAddr],
) -> Result<Vec<String>, String> {
    let has_policy = matches!(&auth.action, NetworkAction::Allow { matched_policy } if matched_policy.is_some());
    let raw_allowed_ips = if has_policy {
        auth.endpoint_configs.first().map(|c| endpoint_config_string_array(c, "allowed_ips")).unwrap_or_default()
    } else {
        vec![]
    };
    let plan = build_validation_plan(host, &host.to_ascii_lowercase(), None, None, &raw_allowed_ips,
                                     auth.exact_declared_endpoint_host)
        .map_err(|d| d.reason)?;
    // resolve_socket_addrs: an IP-literal host resolves to itself.
    let lookup = host.strip_prefix('[').and_then(|h| h.strip_suffix(']')).unwrap_or(host);
    let addrs: Vec<SocketAddr> = match lookup.parse::<IpAddr>() {
        Ok(ip) => vec![SocketAddr::new(ip, port)],
        Err(_) => resolved.iter().map(|ip| SocketAddr::new(*ip, port)).collect(),
    };
    match &plan.address_authorization {
        AddressAuthorization::ExplicitAllowedIps(nets) => validate_allowed_ips_for_resolved_addrs(host, port, &addrs, nets)?,
        AddressAuthorization::ImplicitIpLiteral(ip) => {
            validate_allowed_ips_for_resolved_addrs(host, port, &addrs, &[ipnet::IpNet::from(*ip)])?
        }
        AddressAuthorization::ExactDeclaredHost => validate_declared_endpoint_resolved_addrs(host, port, &addrs)?,
        AddressAuthorization::DefaultPublicOnly => reject_internal_resolved_addrs(host, &addrs)?,
        other => return Err(format!("unsupported plan {other:?}")),
    }
    Ok(addrs.iter().map(|a| a.ip().to_string()).collect())
}
