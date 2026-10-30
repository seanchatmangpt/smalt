#!/usr/bin/env python3
"""
priv/ontologies/fixtures/probe_closed_shapes.py
Red-before-green falsifier court for the 9 sh:closed shapes
(priv/ontologies/public-cloud-core.ttl).

For each shape: a constructed POSITIVE individual (carrying exactly the
admitted property inventory) validates clean under pyshacl; a MUTATED
individual (extra property, wrong datatype, or pattern-violating value)
FAILS CLOSED.

Exit 0 = green, 1 = any probe failed. Run:
    python3 priv/ontologies/fixtures/probe_closed_shapes.py
"""

import sys
from rdflib import Graph, Namespace, URIRef, Literal, RDF, XSD
from pyshacl import validate

SH = Namespace("http://www.w3.org/ns/shacl#")
TOSCA = Namespace("http://docs.oasis-open.org/tosca/ns/simple/yaml/1.3/")
CIMI = Namespace("http://schemas.dmtf.org/cimi/2/")
RBAC = Namespace("http://csrc.nist.gov/ns/rbac#")
KMIP = Namespace("http://docs.oasis-open.org/kmip/ns/v1.4#")
ACL = Namespace("http://www.w3.org/ns/auth/acl#")
SEC = Namespace("https://w3id.org/security#")
ORG = Namespace("http://www.w3.org/ns/org#")
DCTERMS = Namespace("http://purl.org/dc/terms/")

SHAPES_GRAPH = Graph()
SHAPES_GRAPH.parse("priv/ontologies/public-cloud-core.ttl", format="turtle")

RESULTS = []


def run(label, triples, expect_conform, mutation_desc):
    g = Graph()
    for t in triples:
        g.add(t)
    conforms, _, text = validate(
        data_graph=g, shacl_graph=SHAPES_GRAPH, inference="rdfs", advanced=True
    )
    ok = conforms == expect_conform
    RESULTS.append(ok)
    print("[{}] {:<36} {:<34} conforms={} expected={}".format(
        "PASS" if ok else "FAIL", label, mutation_desc, conforms, expect_conform))
    if not ok:
        print(text)


def main():
    # ---- 1. tosca:ContainerApplicationShape -------------------------------
    app = URIRef("ex:app")
    root = URIRef("ex:root")
    base = [
        (app, RDF.type, TOSCA["tosca.nodes.Container.Application"]),
        (app, DCTERMS.identifier, Literal("app-1")),
        (app, ORG.organizationalUnit, Literal("unit-a")),
        (app, TOSCA.artifacts, Literal("registry.example/img:1")),
        (app, TOSCA.requirements, root),
        (root, RDF.type, TOSCA["tosca.nodes.Root"]),
        (app, SEC.digest, Literal("a" * 64)),
    ]
    run("ContainerApplicationShape", base, True, "positive")
    run("ContainerApplicationShape",
        base + [(app, DCTERMS.title, Literal("extra"))], False,
        "mutated: extra closed-world property")

    # ---- 2. tosca:ObjectStorageShape --------------------------------------
    store = URIRef("ex:bucket")
    base = [
        (store, RDF.type, TOSCA["tosca.nodes.Storage.ObjectStorage"]),
        (store, DCTERMS.identifier, Literal("bucket-1")),
        (store, ORG.organizationalUnit, Literal("unit-a")),
        (store, DCTERMS.temporal, Literal(365, datatype=XSD.integer)),
        (store, SEC.digest, Literal("b" * 64)),
    ]
    run("ObjectStorageShape", base, True, "positive")
    run("ObjectStorageShape",
        base + [(store, DCTERMS.spatial, Literal("eastus"))], False,
        "mutated: extra closed-world property")

    # ---- 3. kmip:ManagedSecretShape ---------------------------------------
    secret = URIRef("ex:secret")
    base = [
        (secret, RDF.type, KMIP.SecretData),
        (secret, DCTERMS.identifier, Literal("secret-1")),
        (secret, ORG.organizationalUnit, Literal("unit-a")),
        (secret, KMIP.state, Literal("Active")),
        (secret, SEC.digest, Literal("c" * 64)),
    ]
    run("ManagedSecretShape", base, True, "positive")
    run("ManagedSecretShape",
        base + [(secret, KMIP.state, Literal("Compromised"))], False,
        "mutated: kmip:state outside sh:in")

    # ---- 4. acl:AuthorizationShape ----------------------------------------
    authz = URIRef("ex:authz")
    subj = URIRef("ex:subject")
    role = URIRef("ex:role")
    base = [
        (authz, RDF.type, ACL.Authorization),
        (authz, ACL.agent, subj),
        (subj, RDF.type, RBAC.Subject),
        (authz, RBAC.role, role),
        (role, RDF.type, RBAC.Role),
        # ex:role is itself targeted by rbac:RoleDefinitionShape (class target);
        # it must be a conforming RoleDefinition too.
        (role, DCTERMS.identifier,
         Literal("01234567-89ab-cdef-0123-456789abcdef")),
        (role, DCTERMS.title, Literal("Reader")),
        (role, ACL.accessTo, root),
        (authz, ACL.accessTo, root),
        (root, RDF.type, TOSCA["tosca.nodes.Root"]),
        (authz, ACL.mode, URIRef("http://www.w3.org/ns/auth/acl#Read")),
        (ACL.Read, RDF.type, ACL.Mode),
        (authz, SEC.digest, Literal("d" * 64)),
    ]
    run("AuthorizationShape", base, True, "positive")
    run("AuthorizationShape",
        base + [(authz, DCTERMS.title, Literal("extra"))], False,
        "mutated: extra closed-world property")

    # ---- 5. tosca:ResourceGroupShape --------------------------------------
    rg = URIRef("ex:rg")
    base = [
        (rg, RDF.type, ORG.OrganizationalUnit),
        (rg, DCTERMS.identifier,
         Literal("/subscriptions/abc/resourceGroups/rg-1")),
        (rg, DCTERMS.title, Literal("rg-1")),
        (rg, DCTERMS.spatial, Literal("eastus")),
    ]
    run("ResourceGroupShape", base, True, "positive")
    run("ResourceGroupShape",
        base + [(rg, DCTERMS.spatial, Literal("West US 2"))], False,
        "mutated: spatial pattern violation")

    # ---- 6. tosca:ContainerEnvironmentShape -------------------------------
    env = URIRef("ex:env")
    base = [
        (env, RDF.type, TOSCA["tosca.nodes.Container.Runtime"]),
        (env, DCTERMS.identifier,
         Literal("/subscriptions/abc/resourceGroups/rg-1/providers/"
                 "Microsoft.App/managedEnvironments/env-1")),
        (env, DCTERMS.title, Literal("env-1")),
        (env, DCTERMS.spatial, Literal("eastus")),
    ]
    run("ContainerEnvironmentShape", base, True, "positive")
    run("ContainerEnvironmentShape",
        base + [(env, DCTERMS.identifier, Literal("env-1"))], False,
        "mutated: identifier not ARM managedEnvironment ID")

    # ---- 7. kmip:ManagedKeyShape ------------------------------------------
    key = URIRef("ex:key")
    base = [
        (key, RDF.type, KMIP.Key),
        (key, DCTERMS.identifier, Literal("key-1")),
        (key, ORG.organizationalUnit, Literal("unit-a")),
        (key, KMIP.state, Literal("Active")),
        (key, KMIP.CryptographicLength, Literal(256, datatype=XSD.integer)),
    ]
    run("ManagedKeyShape", base, True, "positive")
    run("ManagedKeyShape",
        base + [(key, KMIP.state, Literal("Compromised"))], False,
        "mutated: kmip:state outside sh:in")

    # ---- 8. rbac:RoleDefinitionShape --------------------------------------
    rd = URIRef("ex:roledef")
    base = [
        (rd, RDF.type, RBAC.Role),
        (rd, DCTERMS.identifier,
         Literal("01234567-89ab-cdef-0123-456789abcdef")),
        (rd, DCTERMS.title, Literal("Reader")),
        (rd, ACL.accessTo, root),
        (root, RDF.type, TOSCA["tosca.nodes.Root"]),
    ]
    run("RoleDefinitionShape", base, True, "positive")
    run("RoleDefinitionShape",
        base + [(rd, DCTERMS.identifier, Literal("not-a-guid"))], False,
        "mutated: identifier GUID pattern violation")

    # ---- 9. tosca:ArmResourceIdentifierShape ------------------------------
    res = URIRef("ex:res")
    base = [
        (res, RDF.type, CIMI.Resource),
        (res, DCTERMS.identifier,
         Literal("/subscriptions/abc/resourceGroups/rg-1/providers/"
                 "Microsoft.KeyVault/vaults/v-1")),
    ]
    run("ArmResourceIdentifierShape", base, True, "positive")
    run("ArmResourceIdentifierShape",
        base + [(res, DCTERMS.identifier, Literal("vaults/v-1"))], False,
        "mutated: identifier not ARM ID geometry")

    if all(RESULTS):
        print("-" * 72)
        print("VERDICT: ALIVE [GREEN] - 9 positive + 9 negative probes, "
              "all shapes fail-closed")
        sys.exit(0)
    print("-" * 72)
    print("VERDICT: FAIL - mutated individual was ADMITTED (vacuous gate)")
    sys.exit(1)


if __name__ == "__main__":
    main()
