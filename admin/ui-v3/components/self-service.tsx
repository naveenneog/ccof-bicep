import { useQuery } from "../lib/api.ts";
import { Button, ErrorNote, Loading, Section } from "./ui.tsx";
import { Operations } from "./self-service-operations.tsx";
import { ConfigurationHistory } from "./self-service-history.tsx";
import type { Capabilities, SelfServiceProps } from "./self-service-shared.tsx";

export { OperationActions, OperationProgress } from "./self-service-operations.tsx";

export function SelfService(props: SelfServiceProps) {
  const capabilities = useQuery<Capabilities>("/api/v3/self-service/capabilities");
  return <div className="stack">
    {props.readOnly && <p className="notice notice-warn" role="status">This project is read-only. An editor on an active project can run operations and preview or restore configuration.</p>}
    {capabilities.error && capabilities.data && <ErrorNote error={capabilities.error} retry={capabilities.reload} />}
    {capabilities.loading && !capabilities.data ? <Loading label="Loading operation capabilities" rows={3} /> : capabilities.error && !capabilities.data ?
      <Section title="Operations unavailable"><ErrorNote error={capabilities.error} retry={capabilities.reload} /></Section> : <>
        <Operations key={props.projectId} {...props} capabilities={capabilities.data ?? {}} />
        <ConfigurationHistory key={props.projectId} {...props} capability={capabilities.data?.history} />
        <div className="form-actions"><Button size="small" variant="quiet" busy={capabilities.loading} onClick={capabilities.reload}>Recheck operation permissions</Button></div>
      </>}
  </div>;
}
