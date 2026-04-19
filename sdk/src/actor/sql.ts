// Sql impl — proxies to engine over tunnel. Every call is a round-trip;
// M3 will add prepared-statement caching and local txn buffering.

import { Op, type Tunnel } from "../tunnel.js";
import type { Sql } from "../types.js";

export class SqlImpl implements Sql {
  constructor(
    private readonly tunnel: Tunnel,
    private readonly sessionId: string,
  ) {}

  exec(sql: string, params: readonly unknown[] = []): Promise<void> {
    return this.tunnel.request<void>(Op.SqlExec, {
      sid: this.sessionId,
      sql,
      params,
    });
  }

  query<T = Record<string, unknown>>(
    sql: string,
    params: readonly unknown[] = [],
  ): Promise<T[]> {
    return this.tunnel.request<T[]>(Op.SqlQuery, {
      sid: this.sessionId,
      sql,
      params,
    });
  }

  async transaction<T>(fn: () => Promise<T>): Promise<T> {
    await this.exec("BEGIN");
    try {
      const result = await fn();
      await this.exec("COMMIT");
      return result;
    } catch (e) {
      await this.exec("ROLLBACK").catch(() => {});
      throw e;
    }
  }
}
