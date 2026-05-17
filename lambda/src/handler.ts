import {
  Route53Client,
  ChangeResourceRecordSetsCommand,
  ChangeAction,
  RRType,
} from "@aws-sdk/client-route-53";
import type { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";

const route53 = new Route53Client({});

const HOSTED_ZONE_ID = process.env.HOSTED_ZONE_ID!;
const RECORD_NAMES = process.env.RECORD_NAMES!.split(",").map((n) => n.trim());
const TTL = parseInt(process.env.TTL ?? "60", 10);

export const handler = async (
  event: APIGatewayProxyEvent
): Promise<APIGatewayProxyResult> => {
  if (event.httpMethod === "GET" && event.resource === "/health") {
    return {
      statusCode: 200,
      body: JSON.stringify({ status: "ok", timestamp: new Date().toISOString() }),
    };
  }

  const ip =
    event.requestContext.identity?.sourceIp ??
    event.headers["X-Forwarded-For"]?.split(",")[0]?.trim();

  if (!ip) {
    return { statusCode: 400, body: JSON.stringify({ error: "Cannot determine source IP" }) };
  }

  await route53.send(
    new ChangeResourceRecordSetsCommand({
      HostedZoneId: HOSTED_ZONE_ID,
      ChangeBatch: {
        Comment: `DDNS update from home server at ${new Date().toISOString()}`,
        Changes: RECORD_NAMES.map((name) => ({
          Action: ChangeAction.UPSERT,
          ResourceRecordSet: {
            Name: name,
            Type: RRType.A,
            TTL,
            ResourceRecords: [{ Value: ip }],
          },
        })),
      },
    })
  );

  console.log(JSON.stringify({ records: RECORD_NAMES, ip, updated: true }));
  return {
    statusCode: 200,
    body: JSON.stringify({ records: RECORD_NAMES, ip, updated: true }),
  };
};
