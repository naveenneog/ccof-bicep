using System.Text.Json;
using Kusto.Language;
using Kusto.Language.Symbols;

var schemas = new[] {
    new TableSymbol("ApiManagementGatewayLogs", "(TimeGenerated:datetime, _ResourceId:string, CorrelationId:string, ResponseCode:long, BackendResponseCode:long, BackendId:string, BackendUrl:string, LastErrorReason:string, LastErrorSource:string, LastErrorSection:string, Errors:dynamic, TraceRecords:dynamic)"),
    new TableSymbol("ApiManagementGatewayLlmLog", "(TimeGenerated:datetime, _ResourceId:string, CorrelationId:string, RequestId:string, ModelName:string, DeploymentName:string, PromptTokens:long, CompletionTokens:long, IsStreamCompletion:bool)")
};
var database = new DatabaseSymbol("offline", schemas);
var globals = GlobalState.Default.WithDatabase(database);
var queries = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(args[0]))!;
var failed = false;
foreach (var (name, text) in queries) {
    var code = KustoCode.ParseAndAnalyze(text, globals);
    var errors = code.GetDiagnostics().Where(d => d.Severity.ToString().Equals("Error", StringComparison.OrdinalIgnoreCase)).ToArray();
    Console.WriteLine($"{name}: {errors.Length} KQL errors");
    foreach (var diagnostic in errors) {
        var before = text[..Math.Min(diagnostic.Start, text.Length)];
        var line = before.Count(c => c == '\n') + 1;
        Console.WriteLine($"  line {line}: {diagnostic.Message}");
    }
    failed |= errors.Length != 0;
}
return failed ? 1 : 0;
