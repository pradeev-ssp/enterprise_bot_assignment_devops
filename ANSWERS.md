# Q1: Moving from ingress-nginx to Gateway API

I'd start by checking what the 40 Ingresses actually do, especially anything
configured through nginx annotations. Hosts and paths are only part of it;
auth, rewrites, TLS, sticky sessions and timeouts need checking too. That list
would guide the controller choice, since support varies between implementations.

Then I'd bring up the Gateway API controller and its CRDs alongside
ingress-nginx, with a separate address, and create the Gateway and HTTPRoutes
against the same backend Services. The [migration guide](https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress/)
covers the basic mapping, but each hostname still needs testing against the new
address with the correct Host header and TLS SNI. Rewrites, path matching,
WebSockets and client IP handling are where I'd expect behaviour to differ.
Certificates and auth flows need testing before sending users there.

For the traffic switch, I'd start with one low-risk hostname and watch errors
and latency before moving the next batch. An upstream load balancer, where
available, would allow controlled traffic shifts and rollback. With DNS, I'd
lower the TTL beforehand and allow for cached records. Both endpoints would
stay running while DNS settles and existing connections drain. I'd remove
ingress-nginx only after application checks pass and traffic stays stable.
