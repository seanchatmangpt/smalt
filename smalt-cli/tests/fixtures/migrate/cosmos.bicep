// Cosmos DB account + database + container (bicep)
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2023-04-15' = {
  name: 'smalt-cosmos'
  location: 'westus'
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
  }
}

resource smaltDb 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2023-04-15' = {
  parent: cosmosAccount
  name: 'orders'
  properties: {
    options: { throughput: 400 }
  }
}

resource ordersContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2023-04-15' = {
  parent: smaltDb
  name: 'orderItems'
  properties: {
    partitionKey: {
      paths: ['/customerId']
    }
  }
}
