targetScope = 'resourceGroup'

@minLength(1)
param workbookResourceName string

@minLength(1)
param workbookDisplayName string

@minLength(1)
param location string

@minLength(1)
param workspaceResourceId string

resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: workbookResourceName
  location: location
  kind: 'shared'
  properties: {
    displayName: workbookDisplayName
    category: 'workbook'
    version: 'Notebook/1.0'
    sourceId: workspaceResourceId
    serializedData: string({
      version: 'Notebook/1.0'
      fallbackResourceIds: [workspaceResourceId]
      items: [
        {
          type: 1
          name: 'awaiting-configuration'
          content: {
            json: 'This workbook resource is ready for D2. Report configuration has not been deployed.'
          }
        }
      ]
    })
  }
}

output workbookResourceId string = workbook.id
