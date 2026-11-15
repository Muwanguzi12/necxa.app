begin;

create index if not exists ticket_replies_ticket_created_idx
  on public.ticket_replies (ticket_id, created_at desc);

commit;
