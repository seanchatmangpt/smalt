// Blob container
resource blobCtn 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: 'smaltacct/default/smalt-blobs'
  // parent derived from the slash name: smaltacct/default -> container 'smalt-blobs'
}

resource otherCtn 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: 'acct2/other-container'
}
