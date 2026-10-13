#Requires -Version 7.0
function New-OnboardingObjectSchema {
    param([hashtable]$Properties)
    @{ type = 'object'; additionalProperties = $false; required = @($Properties.Keys); properties = $Properties }
}

function Get-OnboardingSchema {
    param([Parameter(Mandatory)] [ValidateSet('1','2','3')] [string]$Stage)
    $guid = @{ type = 'string'; pattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' }
    $id = @{ type = 'string'; pattern = '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$' }
    $name = @{ type = 'string'; pattern = '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,119}$' }
    $properties = @{ subscriptionId = $guid; tenantId = $guid }
    if ($Stage -eq '3') {
        $properties.project = Get-OnboardingProjectSchema
        $properties.registry = Get-OnboardingRegistrySchema
        $properties.apimResourceId = @{ type='string'; pattern='^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._-]+/providers/Microsoft\.ApiManagement/service/[A-Za-z0-9-]+$' }
        $properties.resilience = Get-OnboardingResilienceSchema
        $properties.backendRegistrationMode=@{enum=@('designated_foundry','existing_apim')}
        $properties.dependencyValidation=New-OnboardingObjectSchema @{
            mode=@{enum=@('live','approved_plan')}
            validUntil=@{type=@('string','null');pattern='^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'}
        }
        return New-OnboardingObjectSchema $properties
    }
    if ($Stage -eq '2') {
        $scope = '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._-]+/providers/'
        $properties.designatedSubscriptionId = $guid
        $properties.apimResourceId = @{ type='string'; pattern=($scope + 'Microsoft\.ApiManagement/service/[A-Za-z0-9-]+$') }
        $properties.foundryAccountResourceId = @{ type='string'; pattern=($scope + 'Microsoft\.CognitiveServices/accounts/[A-Za-z0-9._-]+$') }
        $properties.reconcilerResourceId = @{ type='string'; pattern=($scope + '(Microsoft\.Web/sites|Microsoft\.ManagedIdentity/userAssignedIdentities)/[A-Za-z0-9_-]+$') }
        $properties.backendId = $id
        $properties.backendAuthMode = @{ enum=@('managedIdentity','managed-identity','second-tenant') }
        $properties.backendFailoverOrder = @{ type='array'; minItems=1; uniqueItems=$true; items=$id }
        $date = @{ type='string'; pattern='^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' }
        $properties.costQueryPeriod = New-OnboardingObjectSchema @{ from=$date; to=$date }
        $properties.backendTenantId=$guid
        $auth=New-OnboardingObjectSchema @{
            mode=@{enum=@('existing-named-values','credential-manager')};clientId=$guid;secretNamedValueId=$id;providerId=$id;connectionId=$id
        }
        $auth.required=@('mode')
        $auth.if=@{properties=@{mode=@{const='credential-manager'}};required=@('mode')}
        $auth.then=@{type='object';required=@('providerId','connectionId')}
        $auth.else=@{type='object';required=@('clientId','secretNamedValueId')}
        $properties.secondTenantAuth=$auth
        $schema=New-OnboardingObjectSchema $properties
        $schema.required=@('subscriptionId','tenantId','apimResourceId','backendId','backendAuthMode')
        $schema.if=@{properties=@{backendAuthMode=@{enum=@('managedIdentity','managed-identity')}};required=@('backendAuthMode')}
        $schema.then=@{type='object';required=@('designatedSubscriptionId','foundryAccountResourceId','reconcilerResourceId','backendFailoverOrder','costQueryPeriod')}
        $schema.else=@{type='object';required=@('backendTenantId','secondTenantAuth')}
        return $schema
    }
    $properties.projectId = $id
    $properties.creationAuthority = @{enum=@('directoryRole','selfServiceOwner')}
    $properties.classifications = @{
        type = 'array'; minItems = 1; uniqueItems = $true
        items = (New-OnboardingObjectSchema @{
            classification = $id; groupName = $name
            mailNickname = @{ type = 'string'; pattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' }
        })
    }
    $properties.projectLeadIds = @{ type = 'array'; minItems = 1; uniqueItems = $true; items = $guid }
    New-OnboardingObjectSchema $properties
}

function Get-OnboardingRegistrySchema {
    New-OnboardingObjectSchema @{
        accountResourceId=@{type='string';pattern='^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[A-Za-z0-9._-]+/providers/Microsoft\.DocumentDB/databaseAccounts/[A-Za-z0-9-]+$'}
        endpoint=@{type='string';pattern='^https://[a-z0-9-]+\.documents\.azure\.com/?$'}
        database=@{type='string';pattern='^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$'}
    }
}
function Get-OnboardingResilienceSchema {
    New-OnboardingObjectSchema @{
        budgetStateGraceSeconds=@{type='integer';minimum=0;maximum=2147483647}
        budgetStateHardLimitSeconds=@{type='integer';minimum=0;maximum=2147483647}
    }
}
function Get-OnboardingProjectSchema {
    $id=@{type='string';pattern='^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$'}
    $guid=@{type='string';pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'}
    $budget=New-OnboardingObjectSchema @{
        amount=@{type='number';minimum=0};currency=@{enum=@('CCU','USD')};period=@{const='monthly'}
    }
    $classification=New-OnboardingObjectSchema @{
        groupId=$guid
        personBudget=$budget;aggregateBudget=@{anyOf=@($budget,@{type='null'})}
        aggregateMode=@{enum=@('strict','notify')};onboardingMode=@{enum=@('block','warn')}
        familyPolicy=Get-OnboardingFamilyPolicySchema
    }
    $classification.properties.classificationGroupDisplayName=@{type='string';minLength=1;maxLength=256}
    $restricted=@{not=@{anyOf=@(@{required=@('fable')},@{required=@('mythos')})}}
    $nonCyb=@{allOf=@($classification,@{properties=@{familyPolicy=@{properties=@{families=$restricted}}}})}
    New-OnboardingObjectSchema @{
        id=$id;projectId=$id;displayName=@{type='string';minLength=1;maxLength=200}
        status=@{const='active'};backendId=$id;designatedSubscriptionId=$guid
        classifications=@{type='object';minProperties=1;propertyNames=$id;additionalProperties=$classification
            patternProperties=@{'^(?!CYB$).+$'=$nonCyb}}
        supersedes=@{type='null'};retiredAt=@{type='null'}
    }
}

function Get-OnboardingTokenLimitsSchema {
    $periods=@('Hourly','Daily','Weekly','Monthly','Yearly')
    $limit=New-OnboardingObjectSchema @{
        tokensPerMinute=@{type=@('integer','null');minimum=1;maximum=2147483647}
        tokenQuota=@{type=@('integer','null');minimum=1;maximum=9007199254740991}
        tokenQuotaPeriod=@{enum=($periods+@($null))}
    }
    $limit.oneOf=@(
        @{properties=@{tokenQuota=@{type='null'};tokenQuotaPeriod=@{type='null'}}}
        @{properties=@{tokenQuota=@{type='integer';minimum=1};tokenQuotaPeriod=@{type='string';enum=$periods}}}
    )
    New-OnboardingObjectSchema @{person=$limit;group=$limit}
}
function Get-OnboardingFamilyPolicySchema {
    $limits=Get-OnboardingTokenLimitsSchema
    $families=@{}
    foreach($family in @('haiku','sonnet','opus','fable','mythos')) {
        $families[$family]=New-OnboardingObjectSchema @{
            models=@{type='array';minItems=1;uniqueItems=$true;items=@{
                type='string';pattern="^(?:claude-$family-[A-Za-z0-9][A-Za-z0-9._-]{0,105}|(?!claude-)[A-Za-z0-9][A-Za-z0-9._-]{0,119})`$(?![\s\S])"
            }}
            person=$limits.properties.person;group=$limits.properties.group
        }
    }
    New-OnboardingObjectSchema @{
        aggregateLimits=$limits
        families=@{type='object';minProperties=1;additionalProperties=$false;properties=$families}
    }
}
Export-ModuleMember -Function Get-OnboardingSchema, New-OnboardingObjectSchema, Get-OnboardingProjectSchema, Get-OnboardingRegistrySchema, Get-OnboardingResilienceSchema, Get-OnboardingTokenLimitsSchema, Get-OnboardingFamilyPolicySchema
