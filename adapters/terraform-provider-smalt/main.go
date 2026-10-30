package main

import (
	"context"
	"flag"
	"log"

	"github.com/hashicorp/terraform-plugin-framework/providerserver"
	"terraform-provider-smalt/internal/provider"
)

func main() {
	var debug bool
	flag.BoolVar(&debug, "debug", false, "set to true to run the provider with support for debuggable provider instances")
	flag.Parse()

	err := providerserver.Serve(context.Background(), provider.New(version), providerserver.ServeOpts{
		// Served address must equal the import address so Terraform's
		// type-name expectations line up under dev_overrides.
		Address: "registry.terraform.io/hashicorp/azurerm",
	})
	if err != nil {
		log.Fatal(err)
	}
}

// version is set for future -ldflags injection; v1 has no release channel.
var version = "dev"
