------------------------ MODULE SchedulerFairness ------------------------
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS TaskCount, PerPriority
ASSUME /\ TaskCount >= 3
       /\ PerPriority \in BOOLEAN

\* Task 1 has priority 0; tasks 2..TaskCount have priority 1.
\* The environment repeatedly wakes, schedules, and blocks task 1.
\* Every cycle contains one opportunity to select a lower-priority task.
Tasks == 1..TaskCount
Priority(t) == IF t = 1 THEN 0 ELSE 1
VARIABLES states, cursor, current, phase, action
vars == <<states, cursor, current, phase, action>>

Init ==
    /\ states = [t \in Tasks |-> IF t = 1 THEN "blocked" ELSE "ready"]
    /\ cursor = <<TaskCount, TaskCount>>
    /\ current = 0
    /\ phase = 0
    /\ action = "init"

Runnable == {t \in Tasks : states[t] \in {"ready", "running"}}
BestPriority == IF 1 \in Runnable THEN 0 ELSE 1
CursorIndex == IF PerPriority THEN BestPriority + 1 ELSE 1
Slot(offset) == ((cursor[CursorIndex] + offset - 1) % TaskCount) + 1
Eligible(offset) == /\ Slot(offset) \in Runnable
                    /\ Priority(Slot(offset)) = BestPriority
FirstOffset == CHOOSE offset \in 1..TaskCount :
    /\ Eligible(offset)
    /\ \A earlier \in 1..(offset - 1) : ~Eligible(earlier)
Chosen == Slot(FirstOffset)

Schedule ==
    /\ phase \in {0, 2}
    /\ states' = [t \in Tasks |->
         IF t = Chosen THEN "running"
         ELSE IF states[t] = "running" THEN "ready" ELSE states[t]]
    /\ cursor' = [cursor EXCEPT ![CursorIndex] = Chosen]
    /\ current' = Chosen
    /\ phase' = phase + 1
    /\ action' = "schedule"

WakeHigh ==
    /\ phase = 1
    /\ states[1] = "blocked"
    /\ states' = [states EXCEPT ![1] = "ready"]
    /\ phase' = 2
    /\ action' = "wake_high"
    /\ UNCHANGED <<cursor, current>>

BlockHigh ==
    /\ phase = 3
    /\ current = 1
    /\ states' = [states EXCEPT ![1] = "blocked"]
    /\ current' = 0
    /\ phase' = 0
    /\ action' = "block_high"
    /\ UNCHANGED cursor

Next == Schedule \/ WakeHigh \/ BlockHigh
\* Fairness applies to environment progress, never to choosing each task.
Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

TypeOK ==
    /\ states \in [Tasks -> {"ready", "running", "blocked"}]
    /\ cursor \in [1..2 -> Tasks]
    /\ current \in 0..TaskCount
    /\ phase \in 0..3
    /\ action \in {"init", "schedule", "wake_high", "block_high"}
SingleRunning == Cardinality({t \in Tasks : states[t] = "running"}) <= 1
CurrentConsistent ==
    {t \in Tasks : states[t] = "running"} =
        IF current = 0 THEN {} ELSE {current}
PrioritySelection == action = "schedule" =>
    \A t \in Runnable : Priority(current) <= Priority(t)
LowProgress == \A t \in 2..TaskCount : []<>(current = t)
=============================================================================
