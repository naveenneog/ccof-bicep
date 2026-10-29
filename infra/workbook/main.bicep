targetScope = 'resourceGroup'

@minLength(1)
param workbookResourceName string

@minLength(1)
param workbookDisplayName string

@minLength(1)
param location string

@minLength(1)
param workspaceResourceId string

@description('Generated offline from the reviewed rate card, canonical ledger and explicit answers.')
param workbookContent object

@description('Serialize before a nested deployment boundary so embedded bracket strings remain literal. Existing object callers use the same serialization by default.')
param workbookSerializedData string = string(workbookContent)

@description('Content digests identify the reviewed inputs without storing credentials.')
param contentTags object

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookResourceName
  location: location
  kind: 'shared'
  tags: contentTags
  properties: {
    displayName: workbookDisplayName
    category: 'workbook'
    version: 'Notebook/1.0'
    sourceId: workspaceResourceId
    serializedData: workbookSerializedData
  }
}

output workbookResourceId string = workbook.id
output portalResourceUrl string = 'https://portal.azure.com/#resource${workbook.id}'
