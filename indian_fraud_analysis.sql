create type gender as ENUM ('Male', 'Female');
create type marital_status as ENUM ('Single', 'Married', 'Divorsed');
create type cust_segment as ENUM ('Basic', 'Gold', 'Platinum', 'Standard');
create type account_type as ENUM ('Savings', 'Salary', 'Current', 'Student');
create type card_status as ENUM ('Active', 'Expired', 'Blocked', 'Lost');
create type card_mode as ENUM ('Physical', 'Virtual');
create type contactless as ENUM ('Yes', 'No');
create type card_type as ENUM ('Classic', 'Gold', 'Platinum', 'Silver');
create type card_network as ENUM ('American Express', 'Mastercard', 'RuPay', 'Visa');
create type merchant_risk_level as ENUM ('Low', 'Medium', 'High');
create type merchant_status as ENUM ('Active', 'Inactive');
create type payment_method as ENUM ('Credit Card', 'Debit Card', 'Net Banking', 'UPI');
create type transaction_channel as ENUM ('ATM', 'Mobile App', 'Online Web', 'POS');
create type transaction_status as ENUM ('Declined', 'Failed', 'Successful');

ALTER TYPE card_network RENAME VALUE 'Rupay' TO 'RuPay';
alter type payment_method rename value 'Debit card' to 'Debit Card';
alter table customer_data add column gender gender;


create table customer_data(
customer_id text unique not null primary key,
customer_name text not null,
gender gender,
age numeric,
marital_status marital_status,
occupation text,
annual_income numeric,
cust_segment cust_segment,
state text,
city text,
account_type account_type,
customer_since date
);

create table card_data(
card_id text unique not null primary key,
customer_id text not null references customer_data(customer_id),
card_type card_type not null,
card_network card_network not null,
credit_limit numeric,
card_status card_status not null,
contactless contactless,
card_mode card_mode not null,
issue_date date,
expiry_date date);

create table merchant(
merchant_id text unique not null primary key,
merchant_name text not null,
merchant_category text,
state text,
city text,
merchant_risk_level merchant_risk_level,
merchant_rating numeric,
merchant_status merchant_status,
merchant_since date
);

create table transactions(
transaction_id text unique not null primary key,
customer_id text not null references customer_data(customer_id),
card_id text not null references card_data(card_id),
merchant_id text not null references merchant(merchant_id),
transaction_date date not null,
transaction_time time,
transaction_amount numeric,
payment_method payment_method,
transaction_channel transaction_channel,
device_type text,
transaction_status transaction_status,
is_international boolean,
fraud_flag boolean,
fraud_reason text,
merchant_risk_level merchant_risk_level,
merchant_category text,
customer_state text,
customer_city text,
merchant_state text,
merchant_city text);


select * from transactions limit 1000;


--Card Network wise fraud counts
select cd.card_network, count(cd.card_network) as network_fraud_counts
from card_data cd inner join transactions t
on cd.card_id = t.card_id
where t.fraud_flag is true
group by cd.card_network;


--Card Mode wise fraud count
select cd.card_mode, count(cd.card_mode) as card_mode_fraud_count
from card_data cd inner join transactions t
on cd.card_id = t.card_id
where t.fraud_flag is true
group by cd.card_mode;

--Contactless wise fraud count
select cd.contactless, count(cd.contactless) as contactless_fraud_count
from card_data cd inner join transactions t
on cd.card_id = t.card_id
where t.fraud_flag is true
group by cd.contactless;


--State-wise total fraud amount loss
select distinct merchant_state, 
sum(transaction_amount) filter(where fraud_flag is true) over(partition by merchant_state) as total_fraud_amount,
round(((sum(transaction_amount) filter(where fraud_flag is true) over(partition by merchant_state)*100.0)/sum(transaction_amount) over(partition by merchant_state)),2) as fraud_money_percentage
from transactions
order by fraud_money_percentage desc;


--Finding 3+ transactions within 10-minutes of window across different merchants

with cte as (select *, 
lead(merchant_id) over(partition by customer_id order by transaction_timestamp asc) as sec_merchant_id,
lead(transaction_timestamp) over(partition by customer_id order by transaction_timestamp asc) as sec_transaction_timestamp,
lead(merchant_id,2) over(partition by customer_id order by transaction_timestamp asc) as third_merchant_id,
lead(transaction_timestamp,2) over(partition by customer_id order by transaction_timestamp asc) as third_transaction_timestamp
from (select t.transaction_id, cd.customer_name, t.customer_id, t.merchant_id, t.transaction_date + t.transaction_time as transaction_timestamp
		from transactions t inner join customer_data cd on t.customer_id = cd.customer_id)
)

select customer_name
from cte
where third_transaction_timestamp - transaction_timestamp <= interval '10 minutes'
and merchant_id != sec_merchant_id
and sec_merchant_id != third_merchant_id
and merchant_id != third_merchant_id;


--Finding transaction pairs where transaction's cities are different and the gap between transaction_date+time is under 2 hours
--Card should be physical
with cte as (
select *, 
lead(transaction_id) over(partition by customer_id order by transaction_timestamp asc) as next_transaction_id,
lead(card_mode) over(partition by customer_id order by transaction_timestamp asc) as next_card_mode,
lead(customer_id) over(partition by customer_id order by transaction_timestamp asc) as next_customer_id,
lead(merchant_city) over(partition by customer_id order by transaction_timestamp asc) as next_merchant_city,
lead(transaction_status) over(partition by customer_id order by transaction_timestamp asc) as next_transaction_status,
lead(transaction_timestamp) over(partition by customer_id order by transaction_timestamp asc) as next_transaction_timestamp
from (select t.transaction_id, t.customer_id, t.transaction_date + t.transaction_time as transaction_timestamp,
		t.merchant_city, t.transaction_status, cd.card_mode
		from transactions t join card_data cd on t.card_id = cd.card_id)
)

select * from cte
where next_transaction_timestamp - transaction_timestamp <= interval '2 hours'
and card_mode = 'Physical' and next_card_mode = 'Physical';


--Repeat frauds within 30 days
with cte as (
select *, 
lead(customer_name) over(partition by customer_id order by transaction_timestamp asc) as next_customer_name,
lead(customer_id) over(partition by customer_id order by transaction_timestamp asc) as next_customer_id,
lead(transaction_timestamp) over(partition by customer_id order by transaction_timestamp asc) as next_transaction_timestamp
from (select t.customer_id, cd.customer_name, t.transaction_date + t.transaction_time as transaction_timestamp
		from transactions t join customer_data cd on t.customer_id = cd.customer_id
		where fraud_flag is true)
)

select customer_id, customer_name
from cte
where next_transaction_timestamp - transaction_timestamp <= interval '30 days';


--Segment wise fraud rate, average transaction amount and average credit_limit utilization
select distinct cd.cust_segment,
round((count(*) filter(where t.fraud_flag is true) over(partition by cd.cust_segment)*100.0) / count(*) over(partition by cd.cust_segment) , 2) as fraud_rate,
round(avg(transaction_amount) over(partition by cd.cust_segment) , 2) as avg_transaction_amount,
round((sum(t.transaction_amount) over(partition by cd.cust_segment)*100.0) / sum(card.credit_limit) over(partition by cd.cust_segment) , 2) as avg_credit_limit_utilisation
from transactions t 
join customer_data cd on t.customer_id = cd.customer_id
join card_data card on t.card_id = card.card_id;


--Fraud rate by merchant category
with cte as (
select distinct m.merchant_category, count(*) filter(where t.fraud_flag is true) over(partition by m.merchant_category) as fraud_count,
count(*) over(partition by m.merchant_category) as total_count
from transactions t join merchant m
on t.merchant_id = m.merchant_id
)

select merchant_category, round((fraud_count*100.0)/total_count, 2) as fraud_rate from cte order by fraud_rate desc;


--Potential Shell companies with unusually high international transactions in compare to their category
with cte as(
select distinct m.merchant_category,count(*) filter(where t.is_international is true) over(partition by m.merchant_category) as int_count,
count(*) over(partition by m.merchant_category) as total_count
from transactions t join merchant m
on t.merchant_id = m.merchant_id
), 
cte2 as (
select merchant_category, round((int_count*100.0)/total_count, 3) as int_avg from cte
)

select distinct m.merchant_id, m.merchant_name, cte2.merchant_category, 
round((count(*) filter(where t.is_international is true) over(partition by m.merchant_id))*100.0/cte2.int_avg, 3) as int_comparison
from merchant m
join cte2 on m.merchant_category = cte2.merchant_category
join transactions t on m. merchant_id = t.merchant_id
order by int_comparison desc;



--Benford's law check
with cte as (
select row_number() over() as first_number from transactions limit 9
)
select c.first_number,
round(sum((case when left(t.transaction_amount::text, 1) = c.first_number::text then 1 else 0 end))*100.0/count(t.transaction_amount), 2) as count
from transactions t, cte c
group by c.first_number
order by c.first_number asc;

